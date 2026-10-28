import Foundation
import WebKit
import UniformTypeIdentifiers

/// `madmd://bundle/` serves the renderer's own assets. `madmd://document/<absolute path>` serves media
/// referenced by the document, as `MediaPolicy` allows, so relative paths may leave its folder.
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    var documentDirectory: URL?
    var reader: DocumentResourceReader = DirectResourceReader()
    // WebKit normalizes `..` in custom scheme URLs, so the base must be absolute for `../` to reach parent folders.
    var documentBaseURL: String {
        guard let directory = documentDirectory else { return "madmd://document/" }
        let path = directory.standardizedFileURL.path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? String($0) }.joined(separator: "/")
        return "madmd://document/" + (path.isEmpty ? "" : path + "/")
    }
    private let assets: URL
    private var active = Set<ObjectIdentifier>()

    init(bundle: Bundle) {
        assets = bundle.resourceURL!.appendingPathComponent("dist", isDirectory: true)
        super.init()
        #if APP_STORE
        reader = FallbackResourceReader(readers: [DirectResourceReader(), Bundle.main.bundleURL.pathExtension == "appex" ? NotificationResourceReader() : XPCResourceReader()])
        #endif
    }

    func documentURL(for request: URL) -> URL? {
        guard request.scheme == "madmd", request.host == "document", request.path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: request.path).standardizedFileURL
    }

    static func resolve(path: String, within root: URL) -> URL? {
        guard let base = canonicalURL(root) else { return nil }
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") && $0 != "." && $0 != ".." }) else { return nil }
        guard let result = canonicalURL(base.appendingPathComponent(relative)) else { return nil }
        guard result.path.hasPrefix(base.path + "/") else { return nil }
        return result
    }

    private static func canonicalURL(_ url: URL) -> URL? {
        var components = Array(url.pathComponents.dropFirst())
        var result = URL(fileURLWithPath: "/", isDirectory: true)
        var links = 0
        while !components.isEmpty {
            let component = components.removeFirst()
            if component == "." { continue }
            if component == ".." { result.deleteLastPathComponent(); continue }
            let candidate = result.appendingPathComponent(component)
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path) {
                links += 1; guard links <= 40 else { return nil }
                if target.hasPrefix("/") { result = URL(fileURLWithPath: "/", isDirectory: true) }
                components = target.split(separator: "/").map(String.init) + components
            } else { result = candidate }
        }
        // Components are already normalized. Foundation's standardization can
        // rewrite /private/var only for existing paths, breaking containment
        // comparisons between an existing folder and a not-yet-existing child.
        return result
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { urlSchemeTask.didFailWithError(CocoaError(.fileReadInvalidFileName)); return }
        if url.host == "document" { serveDocument(url, urlSchemeTask); return }
        do {
            guard url.host == "bundle", let file = Self.resolve(path: url.path, within: assets) else { throw CocoaError(.fileReadNoPermission) }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            let ext = file.pathExtension.lowercased()
            let mime = ["js": "text/javascript", "css": "text/css", "html": "text/html", "svg": "image/svg+xml", "woff2": "font/woff2", "woff": "font/woff", "ttf": "font/ttf"][ext]
                ?? UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*"])!
            urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
        } catch { urlSchemeTask.didFailWithError(error) }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { active.remove(ObjectIdentifier(urlSchemeTask)) }

    /// Byte range requested by a `Range` header; nil serves the whole file, an empty range is unsatisfiable.
    static func byteRange(_ header: String?, length: Int) -> Range<Int>? {
        guard let header, header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let bounds = header.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard bounds.count == 2 else { return nil }
        if bounds[0].isEmpty {
            guard let suffix = Int(bounds[1]), suffix > 0 else { return 0..<0 }
            return max(0, length - suffix)..<length
        }
        guard let start = Int(bounds[0]), start < length else { return 0..<0 }
        let end = bounds[1].isEmpty ? length - 1 : min(Int(bounds[1]) ?? length - 1, length - 1)
        return end >= start ? start..<(end + 1) : 0..<0
    }

    private func serveDocument(_ url: URL, _ task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task); active.insert(id)
        let reader = reader, rangeHeader = task.request.value(forHTTPHeaderField: "Range")
        Task { @MainActor [weak self] in
            defer { self?.active.remove(id) }
            func live() -> Bool { self?.active.contains(id) == true }
            do {
                let resource = try await reader.open(path: url.path)
                let range = Self.byteRange(rangeHeader, length: resource.length)
                var headers = ["Content-Type": resource.mime, "Accept-Ranges": "bytes", "Access-Control-Allow-Origin": "*"]
                if range?.isEmpty == true {
                    headers["Content-Range"] = "bytes */\(resource.length)"
                    guard live() else { return }
                    task.didReceive(HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: headers)!); task.didFinish(); return
                }
                let bytes = range ?? 0..<resource.length
                headers["Content-Length"] = String(bytes.count)
                if range != nil { headers["Content-Range"] = "bytes \(bytes.lowerBound)-\(bytes.upperBound - 1)/\(resource.length)" }
                guard live() else { return }
                task.didReceive(HTTPURLResponse(url: url, statusCode: range == nil ? 200 : 206, httpVersion: "HTTP/1.1", headerFields: headers)!)
                var offset = bytes.lowerBound
                while offset < bytes.upperBound {
                    let count = min(4 << 20, bytes.upperBound - offset), start = offset
                    let chunk = try await Task.detached(priority: .userInitiated) { () throws -> Data in
                        try resource.handle.seek(toOffset: UInt64(start)); return try resource.handle.read(upToCount: count) ?? Data()
                    }.value
                    guard live() else { return }
                    guard !chunk.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                    task.didReceive(chunk); offset += chunk.count
                }
                task.didFinish()
            } catch {
                // A status instead of a failed load lets the preview explain why media is missing.
                guard live() else { return }
                task.didReceive(HTTPURLResponse(url: url, statusCode: MediaPolicy.status(for: error), httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0", "Cache-Control": "no-store", "Access-Control-Allow-Origin": "*"])!)
                task.didFinish()
            }
        }
    }
}
