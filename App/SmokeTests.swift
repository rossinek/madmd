import AppKit
import WebKit
import QuickLookUI

enum SmokeTests {
    @MainActor static func run(reportURL: URL) async {
        var checks: [String] = []
        let started = Date()
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "madmd.tests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks.append(message)
        }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("madmd-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("sample.md")
            let markdown = "# Hello\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n```swift\nlet value = \"hello\"\n```\n\n$x^2$\n\n- [x] task\n\n> [!NOTE]\n> A note\n\n<script>window.pwned=true</script>\n\n![local](pixel.svg)"
            try Data(markdown.utf8).write(to: url)
            try Data("<svg xmlns='http://www.w3.org/2000/svg' width='12' height='12'><rect width='12' height='12' fill='red'/></svg>".utf8).write(to: directory.appendingPathComponent("pixel.svg"))
            let file = try MarkdownFile.read(url)
            try check(file.text == markdown, "UTF-8 read")
            let utf16 = directory.appendingPathComponent("utf16.md")
            try (Data([0xFF, 0xFE]) + "# café\r\n".data(using: .utf16LittleEndian)!).write(to: utf16)
            let decoded = try MarkdownFile.read(utf16)
            try check(try decoded.data(for: decoded.text) == Data(contentsOf: utf16), "UTF-16, BOM and CRLF round trip")
            try check(AssetSchemeHandler.resolve(path: "/../secret", within: directory) == nil, "Path traversal blocked")
            try check(AssetSchemeHandler.resolve(path: "/.env", within: directory) == nil, "Hidden file access blocked")
            let outside = directory.deletingLastPathComponent().appendingPathComponent("madmd-outside-\(UUID().uuidString)")
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("escape"), withDestinationURL: outside)
            try check(AssetSchemeHandler.resolve(path: "/escape/image.png", within: directory) == nil, "Symlink escapes blocked")
            let notes = directory.appendingPathComponent("notes")
            try FileManager.default.createDirectory(at: notes.appendingPathComponent(".github"), withIntermediateDirectories: true)
            let scheme = AssetSchemeHandler(bundle: .main); scheme.documentDirectory = notes
            try check(scheme.documentBaseURL == "madmd://document" + notes.standardizedFileURL.path + "/", "Document base is the absolute document folder")
            let imageData = Data("parent image".utf8)
            try imageData.write(to: directory.appendingPathComponent("parent.png"))
            try check(try MediaPolicy.open(path: directory.appendingPathComponent("parent.png").path).handle.readToEnd() == imageData, "Media outside the document folder loads")
            try imageData.write(to: notes.appendingPathComponent(".github/logo.png"))
            try check((try? MediaPolicy.open(path: notes.appendingPathComponent(".github/logo.png").path)) != nil, "Media in hidden folders loads")
            let secret = directory.appendingPathComponent("secret.txt")
            try Data("secret".utf8).write(to: secret)
            func blocked(_ path: String) -> Bool { do { _ = try MediaPolicy.open(path: path); return false } catch { return (error as? CocoaError)?.code == MediaPolicy.blocked.code } }
            try check(blocked(secret.path), "Non-media files are refused")
            try FileManager.default.createSymbolicLink(at: notes.appendingPathComponent("disguised.png"), withDestinationURL: secret)
            try check(blocked(notes.appendingPathComponent("disguised.png").path), "Media symlinks to other files are refused")
            try FileManager.default.createDirectory(at: notes.appendingPathComponent("folder.png"), withIntermediateDirectories: true)
            try check(blocked(notes.appendingPathComponent("folder.png").path), "Only regular files are served")
            let huge = notes.appendingPathComponent("huge.png")
            FileManager.default.createFile(atPath: huge.path, contents: nil)
            try FileHandle(forWritingTo: huge).truncate(atOffset: UInt64(MediaPolicy.sizeLimit + 1))
            try check((try? MediaPolicy.open(path: huge.path)) == nil, "Oversized images are refused")
            let fallback = FallbackResourceReader(readers: [DeniedReader(), DirectResourceReader()])
            try check(try await fallback.open(path: directory.appendingPathComponent("parent.png").path).length == imageData.count, "Denied reads fall back to the next reader")
            try check(AssetSchemeHandler.byteRange("bytes=2-5", length: 10) == 2..<6 && AssetSchemeHandler.byteRange("bytes=-3", length: 10) == 7..<10
                      && AssetSchemeHandler.byteRange("bytes=8-", length: 10) == 8..<10 && AssetSchemeHandler.byteRange("bytes=12-", length: 10)?.isEmpty == true
                      && AssetSchemeHandler.byteRange(nil, length: 10) == nil, "Range headers parse")
            let controller = DocumentWindowController(file: file)
            let closeAlert = controller.closeAlert()
            try check(closeAlert.buttons.map(\.title) == ["Cancel", "Save & Quit", "Quit Anyway"], "Close dialog has exactly the requested options")
            try check(closeAlert.buttons[0].keyEquivalent == "\r", "Cancel is the default close action")
            controller.showWindow(nil)
            let renderer = controller.renderer
            var rendered = false
            renderer.onRendered = { rendered = true }
            for _ in 0..<200 where !rendered { try await Task.sleep(for: .milliseconds(50)) }
            func js(_ code: String) async throws -> Any? { try await renderer.webView.callAsyncJavaScript(code, arguments: [:], in: nil, contentWorld: .page) }
            if !rendered {
                let diagnostic = try await js("return {url: location.href, api: typeof window.madmd, html: document.body.innerHTML.slice(0, 2000)}")
                throw NSError(domain: "madmd.tests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Preview did not render: \(String(describing: diagnostic))"])
            }
            try check(rendered, "Real WebKit preview rendered")
            let state = try await js("return window.madmd.inspect()") as? [String: Any] ?? [:]
            try check(state["editorLoaded"] as? Bool == false, "Preview does not load Monaco")
            try check(state["tables"] as? Int == 1, "GFM table rendered")
            try check((state["highlighted"] as? Int ?? 0) > 0, "Syntax highlighting rendered")
            try check((state["math"] as? Int ?? 0) > 0, "Math rendered")
            try check(try await js("return !window.pwned && !document.querySelector('#preview script')") as? Bool == true, "Embedded scripts blocked")
            try await Task.sleep(for: .milliseconds(200))
            try check(try await js("return document.querySelector('#preview img').naturalWidth === 12") as? Bool == true, "Relative image loaded")
            let subtitles = directory.appendingPathComponent("captions.vtt")
            let subtitleData = Data("WEBVTT\n\n00:00.000 --> 00:01.000\nHello".utf8)
            try subtitleData.write(to: subtitles)
            func serve(_ path: String, range: String? = nil) async -> RecordingTask {
                var request = URLRequest(url: URL(string: "madmd://document" + path)!); request.setValue(range, forHTTPHeaderField: "Range")
                let task = RecordingTask(request: request); renderer.scheme.webView(renderer.webView, start: task)
                for _ in 0..<100 where !task.done { try? await Task.sleep(for: .milliseconds(20)) }
                return task
            }
            let ranged = await serve(subtitles.path, range: "bytes=0-5")
            try check(ranged.response?.statusCode == 206 && ranged.response?.value(forHTTPHeaderField: "Content-Range") == "bytes 0-5/\(subtitleData.count)" && ranged.data == Data("WEBVTT".utf8), "Range requests return 206 with the requested bytes")
            let whole = await serve(subtitles.path)
            try check(whole.response?.statusCode == 200 && whole.data == subtitleData, "Requests without Range return the whole file")
            let unsatisfiable = await serve(subtitles.path, range: "bytes=99-")
            try check(unsatisfiable.response?.statusCode == 416, "Unsatisfiable ranges return 416")
            let refused = await serve(secret.path)
            try check(refused.error != nil && refused.response == nil, "Preview cannot load non-media files")
            let stopped = RecordingTask(request: URLRequest(url: URL(string: "madmd://document" + subtitles.path)!))
            renderer.scheme.webView(renderer.webView, start: stopped); renderer.scheme.webView(renderer.webView, stop: stopped)
            try await Task.sleep(for: .milliseconds(200))
            try check(stopped.response == nil && !stopped.done, "Stopped requests receive nothing")
            controller.find(.showFindInterface)
            try await Task.sleep(for: .milliseconds(200))
            try check(renderer.isFindBarVisible && renderer.findBarView != nil, "Native preview find bar opens")
            try check(try await js("return window.madmd.inspect().mode === 'preview' && !window.madmd.inspect().editorLoaded") as? Bool == true, "Find keeps preview active without loading editor")
            renderer.find(.hideFindInterface)
            try check(!renderer.isFindBarVisible, "Native preview find bar closes")
            renderer.setTheme("dark")
            try check(try await js("return getComputedStyle(document.querySelector('.markdown-body')).backgroundColor === 'rgb(13, 17, 23)'") as? Bool == true, "Forced dark appearance")
            renderer.setTheme("light")
            try check(try await js("return getComputedStyle(document.querySelector('.markdown-body')).backgroundColor === 'rgb(255, 255, 255)'") as? Bool == true, "Forced light appearance")
            _ = try await js("document.querySelector('#preview h1').dispatchEvent(new MouseEvent('click', {bubbles: true, metaKey: true})); return true")
            for _ in 0..<100 {
                if try await js("return !!window.madmdEditor") as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try check(try await js("return window.madmd.inspect().mode === 'edit' && window.madmdEditor.getPosition().lineNumber === 1") as? Bool == true, "Command-click opens the clicked source block")
            _ = try await js("await window.madmd.revealSource(4); return true")
            try check(try await js("return window.madmdEditor.getPosition().column === 5") as? Bool == true, "Source navigation preserves character offset")
            try check(try await js("return !!window.madmdEditor && !!document.querySelector('.monaco-editor') && document.querySelector('.monaco-editor').clientHeight > 100") as? Bool == true, "Monaco opens with layout and styles")
            try check(try await js("return !!window.MonacoEnvironment.getWorker()") as? Bool == true, "Monaco Web Worker starts")
            _ = try await js("window.madmdEditor.testEdit('# Changed'); return true")
            try await Task.sleep(for: .milliseconds(100))
            try check(controller.isDirty, "Editor change reaches native dirty state")
            try check(try String(contentsOf: url, encoding: .utf8) == markdown, "Editing does not autosave")
            try check(await controller.save(as: false), "Explicit native save succeeds")
            try check(try String(contentsOf: url, encoding: .utf8) == "# Changed", "Explicit save writes editor contents")
            try check(!controller.isDirty, "Save clears dirty state")
            _ = try await js("window.madmdEditor.testEdit('# Unsaved'); window.madmd.action('undo'); return true")
            try await Task.sleep(for: .milliseconds(100))
            try check(try await renderer.value() == "# Changed", "Monaco undo restores saved contents")
            func waitForText(_ expected: String) async throws { for _ in 0..<80 where controller.text != expected { try await Task.sleep(for: .milliseconds(50)) } }
            for (replacement, message) in [("# Replaced once", "External atomic save reloads the document"), ("# Replaced twice", "Watching follows the replaced file")] {
                try Data(replacement.utf8).write(to: url, options: .atomic)
                try await waitForText(replacement)
                try check(controller.text == replacement, message)
            }
            try FileManager.default.removeItem(at: url)
            try await Task.sleep(for: .milliseconds(300))
            try Data("# Changed".utf8).write(to: url)
            try await waitForText("# Changed")
            try check(controller.text == "# Changed", "Watching resumes after the file is deleted and recreated")
            _ = try await js("await window.madmd.setMode('preview'); await window.madmd.load('```mermaid\\ngraph TD; A-->B;\\n```', 'light', 'test'); return true")
            var diagram = false
            for _ in 0..<200 {
                diagram = try await js("return !!document.querySelector('.diagram svg')") as? Bool == true
                if diagram { break }; try await Task.sleep(for: .milliseconds(50))
            }
            if !diagram {
                let detail = try await js("return {loaded: typeof window.madmdDiagrams, html: document.querySelector('.diagram')?.outerHTML}")
                throw NSError(domain: "madmd.tests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Mermaid: \(String(describing: detail))"])
            }
            try check(diagram, "Mermaid lazy loads and renders")
            let diagramCases: [(String, String, String)] = [
                ("geojson", "{\"type\":\"Point\",\"coordinates\":[21.01,52.23]}", ".leaflet-overlay-pane svg path"),
                ("topojson", "{\"type\":\"Topology\",\"objects\":{\"point\":{\"type\":\"Point\",\"coordinates\":[21.01,52.23]}},\"arcs\":[]}", ".leaflet-overlay-pane svg path"),
                ("stl", "solid triangle\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid triangle", ".model canvas")
            ]
            for (kind, source, selector) in diagramCases {
                let input = "```\(kind)\n\(source)\n```"
                _ = try await renderer.webView.callAsyncJavaScript("await window.madmd.load(text, 'light', 'diagrams'); return true", arguments: ["text": input], in: nil, contentWorld: .page)
                var found = false
                for _ in 0..<100 {
                    found = try await renderer.webView.callAsyncJavaScript("return !!document.querySelector(selector)", arguments: ["selector": selector], in: nil, contentWorld: .page) as? Bool == true
                    if found { break }; try await Task.sleep(for: .milliseconds(50))
                }
                try check(found, "\(kind) renders in WebKit")
            }
            let nested = MarkdownWebView()
            let nestedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            nestedWindow.contentView = nested; nestedWindow.orderFront(nil)
            var nestedRendered = false; nested.onRendered = { nestedRendered = true }
            nested.load(text: "![parent](../pixel.svg)", fileURL: notes.appendingPathComponent("nested.md"), theme: "light")
            for _ in 0..<200 where !nestedRendered { try await Task.sleep(for: .milliseconds(50)) }
            var parentLoaded = false
            for _ in 0..<40 where !parentLoaded {
                parentLoaded = try await nested.webView.callAsyncJavaScript("return document.querySelector('#preview img')?.naturalWidth === 12", arguments: [:], in: nil, contentWorld: .page) as? Bool == true
                if !parentLoaded { try await Task.sleep(for: .milliseconds(50)) }
            }
            try check(parentLoaded, "Images from parent folders load in the preview")
            nestedWindow.orderOut(nil)
            let quickLook = PreviewViewController(); quickLook.loadViewIfNeeded()
            let qlWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
            qlWindow.contentViewController = quickLook; qlWindow.orderFront(nil)
            let qlStart = Date()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                quickLook.preparePreviewOfFile(at: url) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            let qlView = quickLook.view as! MarkdownWebView
            let qlText = try await qlView.webView.callAsyncJavaScript("return document.querySelector('h1')?.textContent", arguments: [:], in: nil, contentWorld: .page) as? String
            try check(qlText == "Changed", "Quick Look completion waits for actual file rendering")
            let quickLookSeconds = Date().timeIntervalSince(qlStart)
            let offscreenPreview = PreviewViewController()
            offscreenPreview.loadViewIfNeeded()
            offscreenPreview.view.frame = .zero
            offscreenPreview.view.layoutSubtreeIfNeeded()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                offscreenPreview.preparePreviewOfFile(at: url) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            try check(true, "Quick Look prepares before the host assigns a visible frame")
            let nextURL = directory.appendingPathComponent("next.md")
            try Data("# Next preview".utf8).write(to: nextURL)
            var cancelledRequests = 0
            for _ in 0..<8 {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    offscreenPreview.preparePreviewOfFile(at: url) { error in
                        if (error as? CocoaError)?.code == .userCancelled { cancelledRequests += 1 }
                    }
                    offscreenPreview.preparePreviewOfFile(at: nextURL) { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
                let heading = try await (offscreenPreview.view as! MarkdownWebView).webView.callAsyncJavaScript("return document.querySelector('h1')?.textContent", arguments: [:], in: nil, contentWorld: .page) as? String
                try check(heading == "Next preview", "Reused Quick Look controller renders the latest file")
            }
            try check(cancelledRequests == 8, "Superseded Quick Look requests complete with cancellation exactly once")
            let report: [String: Any] = ["passed": true, "checks": checks, "seconds": Date().timeIntervalSince(started), "quickLookSeconds": quickLookSeconds]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL)
            exit(0)
        } catch {
            let report: [String: Any] = ["passed": false, "checks": checks, "error": String(describing: error)]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL)
            exit(1)
        }
    }
}

private struct DeniedReader: DocumentResourceReader {
    func open(path: String) async throws -> DocumentResource { throw POSIXError(.EPERM) }
}

private final class RecordingTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var response: HTTPURLResponse?
    var data = Data()
    var error: Error?
    var done = false
    init(request: URLRequest) { self.request = request }
    func didReceive(_ response: URLResponse) { self.response = response as? HTTPURLResponse }
    func didReceive(_ data: Data) { self.data += data }
    func didFinish() { done = true }
    func didFailWithError(_ error: Error) { self.error = error; done = true }
}
