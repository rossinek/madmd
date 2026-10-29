import AppKit
import CryptoKit

// Login item that reads document media for the sandboxed app and Quick Look from folders the user granted.
// It never quits on its own: launchd does not relaunch a cleanly exited login item, and Quick Look cannot wake it.
let home = String(cString: getpwuid(getuid())!.pointee.pw_dir)

/// Security-scoped bookmarks to the granted folders, kept in the helper's own container.
final class Grants {
    private(set) var folders: [(path: String, bookmark: Data, url: URL?)] = []
    private var stored: [Data] {
        get { UserDefaults.standard.array(forKey: "folders") as? [Data] ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "folders") }
    }
    private var paths: [String] {
        get { UserDefaults.standard.stringArray(forKey: "paths") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "paths") }
    }

    /// Unresolvable bookmarks stay: a folder that comes back (a remounted disk, a recreated /tmp folder) works again.
    func restore() {
        folders.forEach { $0.url?.stopAccessingSecurityScopedResource() }
        folders = zip(stored, paths).map { data, path in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource() else { return (path, data, nil) }
            let fresh = stale ? (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)) ?? data : data
            return (url.path, fresh, url)
        }
        save()
    }
    func add(_ url: URL) throws {
        let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        remove(url.path)
        _ = url.startAccessingSecurityScopedResource()
        folders.append((url.path, data, url)); save()
    }
    func remove(_ path: String) {
        folders.filter { $0.path == path }.forEach { $0.url?.stopAccessingSecurityScopedResource() }
        folders.removeAll { $0.path == path }; save()
    }
    private func save() { stored = folders.map(\.bookmark); paths = folders.map(\.path) }
}

final class Helper: NSObject, HelperService, NSXPCListenerDelegate {
    let grants = Grants()
    let listener = NSXPCListener(machServiceName: HelperChannel.identifier)
    private let queue = DispatchQueue(label: "requests", qos: .userInitiated, attributes: .concurrent)

    func start() {
        grants.restore()
        prepareContainer()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(request(_:)), name: HelperChannel.request, object: nil, suspensionBehavior: .deliverImmediately)
        listener.delegate = self; listener.resume()
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.beat() }
        // Reading the protected folders now makes macOS ask for them once, instead of during a later preview.
        // Each prompt blocks the reading thread until it is answered, so keep it off the main thread.
        if !grants.folders.isEmpty { queue.async { for folder in ["Documents", "Desktop", "Downloads"] { _ = try? FileManager.default.contentsOfDirectory(atPath: home + "/" + folder) } } }
    }

    private func prepareContainer() {
        guard let cache = HelperChannel.cache, let keyFile = HelperChannel.keyFile else { return }
        try? FileManager.default.removeItem(at: cache)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        if HelperChannel.key() == nil { try? SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.write(to: keyFile, options: .atomic) }
        beat()
    }

    /// Heartbeat for Quick Look, which gives up at once when the helper is not running; also drops stale answers.
    private func beat() {
        guard let heartbeat = HelperChannel.heartbeat, let cache = HelperChannel.cache else { return }
        try? Data().write(to: heartbeat)
        let old = Date().addingTimeInterval(-30)
        for file in (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < old { try? FileManager.default.removeItem(at: file) }
        }
    }

    @objc private func request(_ notification: Notification) {
        guard let object = notification.object as? String, let colon = object.firstIndex(of: ":"), let key = HelperChannel.key(), let cache = HelperChannel.cache else { return }
        let id = String(object[..<colon])
        guard UUID(uuidString: id) != nil, let path = HelperChannel.unseal(String(object[object.index(after: colon)...]), with: key) else { return }
        queue.async { Self.answer(id: id, path: path, in: cache) }
    }

    private static func answer(id: String, path: String, in cache: URL) {
        var info: [String: Any] = ["status": 200]
        do {
            let resource = try MediaPolicy.open(path: path)
            let copy = cache.appendingPathComponent(id + ".bin").path
            // Clone from the checked descriptor; a plain copy only when the file is on another volume.
            if fclonefileat(resource.handle.fileDescriptor, AT_FDCWD, copy, 0) != 0 {
                guard resource.length <= 200 << 20 else { throw MediaPolicy.tooLarge }
                let out = Darwin.open(copy, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
                guard out >= 0 else { throw POSIXError(.EIO) }
                defer { Darwin.close(out) }
                guard fcopyfile(resource.handle.fileDescriptor, out, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else { throw POSIXError(.EIO) }
            }
            // A clone keeps the original's dates; date it now so cleanup does not remove it while Quick Look reads it.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: copy)
            info["mime"] = resource.mime
        } catch { info["status"] = MediaPolicy.status(for: error) }
        if let data = try? JSONSerialization.data(withJSONObject: info) { try? data.write(to: cache.appendingPathComponent(id + ".meta"), options: .atomic) }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(HelperChannel.requirement)
        connection.exportedInterface = NSXPCInterface(with: HelperService.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func ping(reply: @escaping (String) -> Void) { reply(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") }
    func restart() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) } }
    func folders(reply: @escaping ([String], [Bool]) -> Void) {
        DispatchQueue.main.async { reply(self.grants.folders.map(\.path), self.grants.folders.map { $0.url != nil }) }
    }
    func addFolder(_ path: String, reply: @escaping (String?) -> Void) {
        DispatchQueue.main.async {
            // The app cannot hand over its own access (a URL sent over XPC carries no sandbox extension), so the helper asks itself.
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
            panel.message = "Choose a folder madmd may read images, audio, and video from."
            panel.prompt = "Allow"
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let url = panel.url, (try? self.grants.add(url)) != nil else { reply(nil); return }
            reply(url.path)
        }
    }
    func removeFolder(_ path: String, reply: @escaping () -> Void) { DispatchQueue.main.async { self.grants.remove(path); reply() } }
    func open(_ path: String, reply: @escaping (FileHandle?, Int, String?) -> Void) {
        queue.async {
            do { let resource = try MediaPolicy.open(path: path); reply(resource.handle, 200, resource.mime) }
            catch { reply(nil, MediaPolicy.status(for: error), nil) }
        }
    }
}

let app = NSApplication.shared
let helper = Helper()
app.setActivationPolicy(.accessory)
helper.start()
app.run()
