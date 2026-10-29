import AppKit
import WebKit

final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var owner: MarkdownWebView?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { owner?.receive(message) }
}

final class MarkdownWebView: NSView, WKNavigationDelegate, NSSearchFieldDelegate {
    let webView: WKWebView
    private var webTop: NSLayoutConstraint!
    private let searchField = NSSearchField()
    private let searchStatus = NSTextField(labelWithString: "")
    private(set) var findBarView: NSView?
    private(set) var isFindBarVisible = false
    private var searchRevision = 0
    func find(_ action: NSTextFinder.Action) {
        if action == .hideFindInterface { hideFind(); return }
        if findBarView == nil {
            searchField.placeholderString = "Find in Preview"; searchField.delegate = self
            searchField.widthAnchor.constraint(equalToConstant: 240).isActive = true
            let previous = NSButton(title: "‹", target: self, action: #selector(previousMatch))
            previous.toolTip = "Previous match (⇧⌘G)"
            let next = NSButton(title: "›", target: self, action: #selector(nextMatch))
            next.toolTip = "Next match (⌘G)"
            let done = NSButton(title: "Done", target: self, action: #selector(hideFind))
            let bar = NSStackView(views: [searchField, previous, next, searchStatus, done])
            bar.spacing = 8; bar.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
            bar.translatesAutoresizingMaskIntoConstraints = false; addSubview(bar)
            NSLayoutConstraint.activate([bar.topAnchor.constraint(equalTo: topAnchor), bar.trailingAnchor.constraint(equalTo: trailingAnchor), bar.heightAnchor.constraint(equalToConstant: 40)])
            findBarView = bar
        }
        isFindBarVisible = true; findBarView?.isHidden = false; webTop.constant = 40
        if action == .showFindInterface { window?.makeFirstResponder(searchField); searchField.selectText(nil) }
        else { search(backwards: action == .previousMatch) }
    }
    @objc private func hideFind() {
        isFindBarVisible = false; findBarView?.isHidden = true; webTop.constant = 0
        searchRevision += 1
        webView.find("", configuration: WKFindConfiguration()) { _ in }
        window?.makeFirstResponder(webView)
    }
    @objc private func nextMatch() { search(backwards: false) }
    @objc private func previousMatch() { search(backwards: true) }
    func controlTextDidChange(_ obj: Notification) { search(backwards: false) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { hideFind(); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { search(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true); return true }
        return false
    }
    private func search(backwards: Bool) {
        let configuration = WKFindConfiguration(); configuration.backwards = backwards; configuration.wraps = true; configuration.caseSensitive = false
        searchRevision += 1; let revision = searchRevision; let query = searchField.stringValue
        webView.find(query, configuration: configuration) { [weak self] result in
            guard let self, self.searchRevision == revision else { return }
            self.searchStatus.stringValue = query.isEmpty || result.matchFound ? "" : "Not found"
        }
    }
    let scheme: AssetSchemeHandler
    private let handler = WeakScriptHandler()
    private var ready = false
    private var pendingText = ""
    private var theme = "light"
    private var requestID = UUID().uuidString
    private var hasContent = false
    private var pendingMode = "preview"
    var onEditSource: ((Int) -> Void)?
    var onChange: ((String) -> Void)?
    var onSave: (() -> Void)?
    var onLink: ((URL) -> Void)?
    var onRendered: (() -> Void)?
    var onRender: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    var onWarning: ((Error) -> Void)?
    var onMediaDenied: ((String) -> Void)?
    var onAllowMedia: (() -> Void)?

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
        webTop = webView.topAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([webView.leadingAnchor.constraint(equalTo: leadingAnchor), webView.trailingAnchor.constraint(equalTo: trailingAnchor), webTop, webView.bottomAnchor.constraint(equalTo: bottomAnchor)])
        webView.load(URLRequest(url: URL(string: "madmd://bundle/index.html")!))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @discardableResult func load(text: String, fileURL: URL?, theme: String) -> String {
        pendingText = text; self.theme = theme; hasContent = true; requestID = UUID().uuidString
        scheme.documentDirectory = fileURL?.deletingLastPathComponent()
        if ready { sendContent() }
        return requestID
    }
    /// Renders the current text again, e.g. after access to its media was granted.
    func refresh() { requestID = UUID().uuidString; if ready { sendContent() } }
    private func sendContent() {
        let request = requestID
        webView.callAsyncJavaScript("await window.madmd.load(text, theme, request, baseURL, canNavigate); await window.madmd.setMode(mode)", arguments: ["text": pendingText, "theme": theme, "request": requestID, "mode": pendingMode, "baseURL": scheme.documentBaseURL, "canNavigate": onEditSource != nil], in: nil, in: .page) { [weak self] result in
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
        if mode != "preview" { find(.hideFindInterface) }
        pendingMode = mode
        guard ready else { return }
        webView.callAsyncJavaScript("await window.madmd.setMode(mode)", arguments: ["mode": mode], in: nil, in: .page, completionHandler: nil)
    }
    func action(_ id: String) {
        pendingMode = "edit"
        guard ready else { return }
        webView.callAsyncJavaScript("await window.madmd.setMode('edit'); window.madmd.action(id)", arguments: ["id": id], in: nil, in: .page, completionHandler: nil)
    }
    func revealSource(_ offset: Int) {
        pendingMode = "edit"; find(.hideFindInterface)
        webView.callAsyncJavaScript("await window.madmd.revealSource(offset)", arguments: ["offset": offset], in: nil, in: .page, completionHandler: nil)
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
        case "editSource": if let offset = body["offset"] as? Int { onEditSource?(offset) }
        case "save": onSave?()
        case "link": if let href = body["href"] as? String, let url = URL(string: href) { onLink?(url) }
        case "mediaError":
            guard let id = body["id"] as? String, let src = body["src"] as? String, let url = URL(string: src), let path = scheme.documentURL(for: url)?.path else { return }
            let reader = scheme.reader
            Task { @MainActor [weak self] in
                var status = 200
                do { _ = try await reader.open(path: path) } catch { status = MediaPolicy.status(for: error) }
                _ = try? await self?.webView.callAsyncJavaScript("window.madmd.explainMedia(id, status, allow)", arguments: ["id": id, "status": status, "allow": self?.onAllowMedia != nil], in: nil, contentWorld: .page)
                if status == 403 { self?.onMediaDenied?(path) }
            }
        case "allowMedia": onAllowMedia?()
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
