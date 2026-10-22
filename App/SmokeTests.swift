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
            let repo = directory.appendingPathComponent("repo")
            let docs = repo.appendingPathComponent("docs")
            try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            let repositoryImageData = Data("repository image".utf8)
            try repositoryImageData.write(to: repo.appendingPathComponent("image.png"))
            let scheme = AssetSchemeHandler(bundle: .main); scheme.documentDirectory = docs
            try check(scheme.documentBaseURL == "madmd://document/docs/", "Repository-relative document base")
            let resolvedImage = scheme.documentURL(for: URL(string: "madmd://document/image.png")!)
            try check(resolvedImage != nil && (try? Data(contentsOf: resolvedImage!)) == repositoryImageData, "Parent-folder image paths stay inside repository")
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
            renderer.setTheme("dark")
            try check(try await js("return getComputedStyle(document.querySelector('.markdown-body')).backgroundColor === 'rgb(13, 17, 23)'") as? Bool == true, "Forced dark appearance")
            renderer.setTheme("light")
            try check(try await js("return getComputedStyle(document.querySelector('.markdown-body')).backgroundColor === 'rgb(255, 255, 255)'") as? Bool == true, "Forced light appearance")
            _ = try await js("await window.madmd.setMode('edit'); return true")
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
