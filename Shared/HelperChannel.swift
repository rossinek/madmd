import Foundation
import CryptoKit

/// The App Store build reads media outside the sandbox through a login item helper that holds the
/// user's folder grants. The app talks to it over XPC; Quick Look cannot look up the helper's
/// Mach service, so it posts a distributed notification and reads the answer from the group container.
enum HelperChannel {
    static let team = "H7B584W2D6"
    static let group = "H7B584W2D6.app.madmd"
    static let identifier = "H7B584W2D6.app.madmd.helper"
    static let request = Notification.Name("H7B584W2D6.app.madmd.request")
    // Apple re-signs TestFlight and App Store builds with its own certificates, which carry no team OU,
    // so those are matched by their certificate markers and the bundle identifiers only Apple can sign.
    static let requirement = "anchor apple generic and (identifier \"app.madmd.mac\" or identifier \"\(identifier)\") and "
        + "(certificate leaf[subject.OU] = \"\(team)\" or certificate leaf[field.1.2.840.113635.100.6.1.9] exists"
        + " or certificate leaf[field.1.2.840.113635.100.6.1.25.1] exists)"

    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }
    static var cache: URL? { container?.appendingPathComponent("cache", isDirectory: true) }
    static var heartbeat: URL? { container?.appendingPathComponent("heartbeat") }
    static var keyFile: URL? { container?.appendingPathComponent("key") }

    // Notifications are visible to every process, so the requested path is sealed with a key
    // that only members of the app group can read.
    static func key() -> SymmetricKey? { (keyFile.flatMap { try? Data(contentsOf: $0) }).map(SymmetricKey.init(data:)) }
    static func seal(_ text: String, with key: SymmetricKey) -> String? { try? AES.GCM.seal(Data(text.utf8), using: key).combined?.base64EncodedString() }
    static func unseal(_ text: String, with key: SymmetricKey) -> String? {
        guard let data = Data(base64Encoded: text), let box = try? AES.GCM.SealedBox(combined: data), let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    static func connection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: identifier, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: HelperService.self)
        connection.setCodeSigningRequirement(requirement)
        return connection
    }

    /// Calls the helper and waits for one reply; nil when it is not running or does not answer in time.
    static func call<T>(timeout: Double = 5, _ body: @escaping (HelperService, @escaping (T) -> Void) -> Void) async -> T? {
        await withCheckedContinuation { continuation in
            let connection = connection(), lock = NSLock()
            var finished = false
            func finish(_ value: T?) {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true; continuation.resume(returning: value); connection.invalidate()
            }
            connection.resume()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in finish(nil) }) as? HelperService else { finish(nil); return }
            body(proxy) { finish($0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }
}

@objc protocol HelperService {
    /// The helper's build number, so the app can restart an outdated helper after an update.
    func ping(reply: @escaping (String) -> Void)
    func restart()
    /// Granted folders and whether each one is currently reachable.
    func folders(reply: @escaping ([String], [Bool]) -> Void)
    /// Shows the helper's own open panel at `path`; replies with the chosen folder or nil.
    func addFolder(_ path: String, reply: @escaping (String?) -> Void)
    func removeFolder(_ path: String, reply: @escaping () -> Void)
    /// Opens a file under `MediaPolicy`; replies with a status as in `MediaPolicy.status(for:)`.
    func open(_ path: String, reply: @escaping (FileHandle?, Int, String?) -> Void)
}

struct XPCResourceReader: DocumentResourceReader {
    func open(path: String) async throws -> DocumentResource {
        guard let (handle, status, mime) = await HelperChannel.call(timeout: 10, { (helper, done: @escaping ((FileHandle?, Int, String?)) -> Void) in
            helper.open(path) { done(($0, $1, $2)) }
        }) else { throw POSIXError(.EPERM) }
        guard let handle, let mime, status == 200 else { throw MediaPolicy.error(for: status) }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw POSIXError(.EIO) }
        return DocumentResource(handle: handle, length: Int(info.st_size), mime: mime)
    }
}

/// Quick Look's channel: a sealed request by notification, answered in `cache/<id>.meta` and `cache/<id>.bin`.
/// One copy per file serves every range request for it; the helper removes copies after 30 seconds.
struct NotificationResourceReader: DocumentResourceReader {
    private static var copies: [String: (path: String, mime: String, date: Date)] = [:]
    private static let lock = NSLock()

    func open(path: String) async throws -> DocumentResource {
        let recent = Self.lock.withLock { Self.copies[path].flatMap { Date().timeIntervalSince($0.date) < 20 ? $0 : nil } }
        if let recent, let resource = try? MediaPolicy.open(cached: recent.path, mime: recent.mime) { return resource }
        guard let cache = HelperChannel.cache, let key = HelperChannel.key(), let heartbeat = HelperChannel.heartbeat,
              let beat = try? FileManager.default.attributesOfItem(atPath: heartbeat.path)[.modificationDate] as? Date,
              Date().timeIntervalSince(beat) < 30, let sealed = HelperChannel.seal(path, with: key) else { throw POSIXError(.EPERM) }
        let id = UUID().uuidString
        DistributedNotificationCenter.default().postNotificationName(HelperChannel.request, object: id + ":" + sealed, userInfo: nil, deliverImmediately: true)
        let meta = cache.appendingPathComponent(id + ".meta")
        // Copies are clones on the same volume, so even large videos usually answer within milliseconds.
        for _ in 0..<500 {
            if let data = try? Data(contentsOf: meta), let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let status = info["status"] as? Int {
                guard status == 200, let mime = info["mime"] as? String else { throw MediaPolicy.error(for: status) }
                let copy = cache.appendingPathComponent(id + ".bin").path
                Self.lock.withLock { Self.copies[path] = (copy, mime, Date()) }
                return try MediaPolicy.open(cached: copy, mime: mime)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw POSIXError(.EPERM)
    }
}
