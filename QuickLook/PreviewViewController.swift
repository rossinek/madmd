import AppKit
import QuickLookUI
import WebKit
import OSLog

final class PreviewViewController: NSViewController, QLPreviewingController {
    private var renderer: MarkdownWebView!
    private var completion: ((Error?) -> Void)?
    private var generation = UUID()
    private var accessURL: URL?
    private var timeout: DispatchWorkItem?
    private var expectedRenderID: String?
    private var startedAt = Date()
    private let logger = Logger(subsystem: "app.madmd.mac", category: "QuickLook")

    override func loadView() {
        renderer = MarkdownWebView(bundle: Bundle(for: Self.self))
        view = renderer
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 720)
        preferredContentSize = NSSize(width: 900, height: 720)
        renderer.onRender = { [weak self] renderID in
            guard let self, self.completion != nil, self.expectedRenderID == renderID else { return }
            self.view.layoutSubtreeIfNeeded()
            // This is a live view-based extension. Its rendered-content signal is
            // sufficient; an unrelated snapshot failure must not reject the view.
            self.finish(nil)
        }
        renderer.onError = { [weak self] error in self?.finish(error) }
        renderer.onWarning = { [weak self] error in self?.logger.warning("Optional renderer content failed: \(error.localizedDescription, privacy: .private)") }
    }
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        loadViewIfNeeded()
        finish(CocoaError(.userCancelled))
        generation = UUID(); let request = generation
        expectedRenderID = nil; startedAt = Date()
        logger.info("Preparing preview \(request.uuidString, privacy: .public)")
        completion = handler
        if url.startAccessingSecurityScopedResource() { accessURL = url }
        let work = DispatchWorkItem { [weak self] in
            guard self?.generation == request else { return }
            self?.finish(NSError(domain: "madmd", code: 3, userInfo: [NSLocalizedDescriptionKey: "The preview timed out."]))
        }
        timeout = work; DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
        Task { @MainActor [weak self] in
            do {
                let file = try await Task.detached(priority: .userInitiated) { try MarkdownFile.read(url) }.value
                guard let self, self.generation == request else { return }
                let dark = self.view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                self.expectedRenderID = self.renderer.load(text: file.text, fileURL: url, theme: dark ? "dark" : "light")
            } catch { if self?.generation == request { self?.finish(error) } }
        }
    }
    private func finish(_ error: Error?) {
        guard let completion else { return }
        self.completion = nil; expectedRenderID = nil; timeout?.cancel(); timeout = nil
        let elapsed = Date().timeIntervalSince(startedAt) * 1000
        if let error = error as NSError? {
            logger.error("Preview \(self.generation.uuidString, privacy: .public) failed: \(error.domain, privacy: .public) code \(error.code) after \(elapsed) ms")
        } else { logger.info("Preview \(self.generation.uuidString, privacy: .public) ready after \(elapsed) ms") }
        if let accessURL { accessURL.stopAccessingSecurityScopedResource(); self.accessURL = nil }
        // Release this request's resources before calling the host, which may
        // synchronously prepare another file on the same controller.
        completion(error)
    }
    deinit { timeout?.cancel(); accessURL?.stopAccessingSecurityScopedResource() }
}
