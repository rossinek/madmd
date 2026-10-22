import AppKit
import WebKit

final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var owner: MarkdownWebView?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { owner?.receive(message) }
}

final class MarkdownWebView: NSView, WKNavigationDelegate {
    let webView: WKWebView
    let scheme: AssetSchemeHandler
    private let handler = WeakScriptHandler()
    private var ready = false
    private var pendingText = ""
    private var theme = "light"
    private var requestID = UUID().uuidString
    private var hasContent = false
    private var pendingMode = "preview"
    var onChange: ((String) -> Void)?
    var onSave: (() -> Void)?
    var onLink: ((URL) -> Void)?
    var onRendered: (() -> Void)?
    var onRender: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    var onWarning: ((Error) -> Void)?

    init(bundle: Bundle = .main) {
        scheme = AssetSchemeHandler(bundle: bundle)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(scheme, forURLScheme: "madmd")
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        handler.owner = self
        configuration.userContentController.add(handler, name: "madmd")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([webView.leadingAnchor.constraint(equalTo: leadingAnchor), webView.trailingAnchor.constraint(equalTo: trailingAnchor), webView.topAnchor.constraint(equalTo: topAnchor), webView.bottomAnchor.constraint(equalTo: bottomAnchor)])
        webView.load(URLRequest(url: URL(string: "madmd://bundle/index.html")!))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @discardableResult func load(text: String, fileURL: URL?, theme: String) -> String {
        pendingText = text; self.theme = theme; hasContent = true; requestID = UUID().uuidString
        scheme.documentDirectory = fileURL?.deletingLastPathComponent()
        if ready { sendContent() }
        return requestID
    }
    private func sendContent() {
        let request = requestID
        webView.callAsyncJavaScript("await window.madmd.load(text, theme, request, baseURL); await window.madmd.setMode(mode)", arguments: ["text": pendingText, "theme": theme, "request": requestID, "mode": pendingMode, "baseURL": scheme.documentBaseURL], in: nil, in: .page) { [weak self] result in
            guard let self, self.requestID == request else { return }
            if case .failure(let error) = result { self.onError?(error) }
        }
    }
    func setTheme(_ value: String) {
        theme = value
        guard ready else { return }
        webView.callAsyncJavaScript("window.madmd.setTheme(theme)", arguments: ["theme": value], in: nil, in: .page, completionHandler: nil)
    }
    func setMode(_ mode: String) {
        pendingMode = mode
        guard ready else { return }
        webView.callAsyncJavaScript("await window.madmd.setMode(mode)", arguments: ["mode": mode], in: nil, in: .page, completionHandler: nil)
    }
    func action(_ id: String) {
        pendingMode = "edit"
        guard ready else { return }
        webView.callAsyncJavaScript("await window.madmd.setMode('edit'); window.madmd.action(id)", arguments: ["id": id], in: nil, in: .page, completionHandler: nil)
    }
    func markSaved() {
        guard ready else { return }
        webView.callAsyncJavaScript("window.madmd.markSaved()", in: nil, in: .page, completionHandler: nil)
    }
    func setDocumentURL(_ url: URL) {
        scheme.documentDirectory = url.deletingLastPathComponent()
        guard ready else { return }
        webView.callAsyncJavaScript("window.madmd.setBaseURL(baseURL)", arguments: ["baseURL": scheme.documentBaseURL], in: nil, in: .page, completionHandler: nil)
    }
    func value() async throws -> String {
        guard ready else { return pendingText }
        return try await webView.callAsyncJavaScript("return window.madmd.getValue()", arguments: [:], in: nil, contentWorld: .page) as? String ?? pendingText
    }
    func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.scheme == "madmd", message.frameInfo.request.url?.host == "bundle",
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready": ready = true; if hasContent { sendContent() }
        case "changed": if let text = body["text"] as? String { pendingText = text; onChange?(text) }
        case "save": onSave?()
        case "link": if let href = body["href"] as? String, let url = URL(string: href) { onLink?(url) }
        case "rendered": if hasContent && body["request"] as? String == requestID { onRender?(requestID); onRendered?() }
        case "error": onError?(NSError(domain: "madmd", code: 2, userInfo: [NSLocalizedDescriptionKey: body["message"] as? String ?? "Preview failed."]))
        case "warning": onWarning?(NSError(domain: "madmd", code: 4, userInfo: [NSLocalizedDescriptionKey: body["message"] as? String ?? "Optional preview content failed."]))
        default: break
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .other && navigationAction.request.url?.host == "bundle" { decisionHandler(.allow) }
        else { decisionHandler(.cancel); if let url = navigationAction.request.url { onLink?(url) } }
    }
    private func navigationFailed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        onError?(error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { ready = false; webView.reload() }
}
