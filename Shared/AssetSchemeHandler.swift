import Foundation
import WebKit
import UniformTypeIdentifiers

/// Only bundled application assets and files under the document folder/repository
/// are exposed. Canonical path checks also prevent escapes through symlinks.
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    var documentDirectory: URL? {
        didSet {
            resourceRoot = documentDirectory
            guard let documentDirectory else { return }
            var candidate = documentDirectory
            while candidate.path != "/" {
                if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(".git").path) {
                    resourceRoot = candidate; break
                }
                candidate.deleteLastPathComponent()
            }
        }
    }
    private var resourceRoot: URL?
    var documentBaseURL: String {
        guard let directory = documentDirectory, let root = resourceRoot else { return "madmd://document/" }
        let suffix = String(directory.path.dropFirst(root.path.count))
        let path = suffix.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? String($0) }.joined(separator: "/")
        return "madmd://document/" + (path.isEmpty ? "" : path + "/")
    }
    private let assets: URL

    init(bundle: Bundle) {
        assets = bundle.resourceURL!.appendingPathComponent("dist", isDirectory: true)
        super.init()
    }

    func documentURL(for request: URL) -> URL? {
        guard request.scheme == "madmd", request.host == "document", let root = resourceRoot else { return nil }
        return Self.resolve(path: request.path, within: root)
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
        let file = url.host == "bundle" ? Self.resolve(path: url.path, within: assets) : documentURL(for: url)
        do {
            guard let file else { throw CocoaError(.fileReadNoPermission) }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            let ext = file.pathExtension.lowercased()
            let mime = ["js": "text/javascript", "css": "text/css", "html": "text/html", "svg": "image/svg+xml", "woff2": "font/woff2", "woff": "font/woff", "ttf": "font/ttf"][ext]
                ?? UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*"])!
            urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
        } catch { urlSchemeTask.didFailWithError(error) }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
