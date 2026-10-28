#if APP_STORE
import AppKit
import ServiceManagement

/// Full previews: the login item helper that reads media next to documents for the sandboxed app and Quick Look.
@MainActor final class FullPreviews {
    static let shared = FullPreviews()
    private let service = SMAppService.loginItem(identifier: HelperChannel.identifier)
    var isEnabled: Bool { service.status == .enabled }
    var onChange: (() -> Void)?

    func ping() async -> String? { await HelperChannel.call(timeout: 2) { helper, done in helper.ping(reply: done) } }

    /// Waits for launchd to start the helper (or for a call to launch it on demand).
    func waitForHelper() async -> Bool {
        for _ in 0..<20 { if await ping() != nil { return true }; try? await Task.sleep(for: .milliseconds(250)) }
        return false
    }

    /// After an update the old helper process keeps running its old code, so replace it.
    func refreshHelper() async {
        guard isEnabled, let version = await ping(), version != Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return }
        await restartHelper()
    }

    /// A fresh process asks macOS for the protected folders inside the granted ones.
    func restartHelper() async {
        let connection = HelperChannel.connection(); connection.resume()
        (connection.remoteObjectProxy as? HelperService)?.restart()
        try? await Task.sleep(for: .milliseconds(600)); connection.invalidate()
        _ = await waitForHelper()
    }

    func enable() async -> Bool {
        do { try service.register() } catch { NSAlert(error: error).runModal(); return false }
        onChange?()
        return await waitForHelper()
    }

    func disable() {
        do { try service.unregister() } catch { NSAlert(error: error).runModal() }
        onChange?()
    }

    func folders() async -> [(path: String, available: Bool)] {
        await HelperChannel.call { (helper, done: @escaping ([(path: String, available: Bool)]) -> Void) in
            helper.folders { paths, available in done(Array(zip(paths, available)).map { (path: $0.0, available: $0.1) }) }
        } ?? []
    }

    /// Enables the helper if needed, lets the user pick a folder in the helper's panel, and returns the chosen path.
    @discardableResult func allowFolder(startingAt path: String) async -> String? {
        if !isEnabled { guard await enable() else { return nil } }
        let chosen: String?? = await HelperChannel.call(timeout: 3600) { helper, done in helper.addFolder(path) { done($0) } }
        guard let chosen = chosen ?? nil else { return nil }
        await restartHelper(); onChange?()
        NotificationCenter.default.post(name: .madmdMediaAccessChanged, object: nil)
        return chosen
    }

    func removeFolder(_ path: String) async {
        _ = await HelperChannel.call { (helper, done: @escaping (Bool) -> Void) in helper.removeFolder(path) { done(true) } }
        onChange?()
    }

    static var home: String { String(cString: getpwuid(getuid())!.pointee.pw_dir) }

    // MARK: - Onboarding

    private var onboarding: NSWindow?

    func showOnboardingIfNeeded() async {
        guard !isEnabled, !UserDefaults.standard.bool(forKey: "fullPreviewsOffered") else { return }
        // Documents opened from Finder arrive after launch; attach to the window the user is looking at.
        try? await Task.sleep(for: .milliseconds(800))
        UserDefaults.standard.set(true, forKey: "fullPreviewsOffered")
        showOnboarding()
    }

    func showOnboarding() {
        if let onboarding { onboarding.makeKeyAndOrderFront(nil); return }
        let title = NSTextField(labelWithString: "Show images, audio, and video in your Markdown")
        title.font = .boldSystemFont(ofSize: 15)
        let body = NSTextField(wrappingLabelWithString: "Markdown files often link to media in nearby folders. To show it in documents and in Quick Look, madmd needs a small helper that runs in the background and reads only images, audio, video, and subtitles from the folders you choose. You can change this later in Settings.")
        let enable = NSButton(title: "Choose Folders…", target: nil, action: nil); enable.keyEquivalent = "\r"
        let later = NSButton(title: "Not Now", target: nil, action: nil)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, later, enable])
        let stack = NSStackView(views: [title, body, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        body.preferredMaxLayoutWidth = 420
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Full Previews"; window.contentView = stack; window.isReleasedWhenClosed = false; window.center()
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        enable.target = self; enable.action = #selector(onboardingEnable)
        later.target = self; later.action = #selector(onboardingLater)
        onboarding = window
        if let host = (NSApp.delegate as? AppDelegate)?.active?.window, host.isVisible { host.beginSheet(window) } else { window.makeKeyAndOrderFront(nil) }
    }

    private func closeOnboarding() {
        guard let window = onboarding else { return }
        if let host = window.sheetParent { host.endSheet(window) } else { window.close() }
        onboarding = nil
    }
    @objc private func onboardingLater() { closeOnboarding() }
    @objc private func onboardingEnable() {
        closeOnboarding()
        Task { await allowFolder(startingAt: Self.home) }
    }

    // MARK: - Settings

    private lazy var settings = FullPreviewsSettings(previews: self)
    func showSettings() { settings.showWindow(nil); settings.window?.makeKeyAndOrderFront(nil); settings.reload() }
}

extension Notification.Name { static let madmdMediaAccessChanged = Notification.Name("madmdMediaAccessChanged") }

/// Settings: the helper switch and the folders it may read.
@MainActor final class FullPreviewsSettings: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let previews: FullPreviews
    private let toggle = NSButton(checkboxWithTitle: "Show media from folders outside the document (Full Previews)", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let buttons = NSSegmentedControl(images: [NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Folder")!, NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove Folder")!], trackingMode: .momentary, target: nil, action: nil)
    private var folders: [(path: String, available: Bool)] = []

    init(previews: FullPreviews) {
        self.previews = previews
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"; window.isReleasedWhenClosed = false
        super.init(window: window)
        let note = NSTextField(wrappingLabelWithString: "A helper runs in the background and reads only images, audio, video, and subtitles from these folders, for documents and Quick Look.")
        note.textColor = .secondaryLabelColor; note.preferredMaxLayoutWidth = 470
        let column = NSTableColumn(identifier: .init("path")); column.title = "Folders"; table.addTableColumn(column)
        table.headerView = nil; table.dataSource = self; table.delegate = self; table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        toggle.target = self; toggle.action = #selector(toggled)
        buttons.target = self; buttons.action = #selector(buttonPressed)
        status.textColor = .secondaryLabelColor; status.lineBreakMode = .byWordWrapping; status.preferredMaxLayoutWidth = 470
        let stack = NSStackView(views: [toggle, note, status, scroll, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        window.contentView = stack
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        window.center()
        previews.onChange = { [weak self] in self?.reload() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func reload() {
        toggle.state = previews.isEnabled ? .on : .off
        buttons.isEnabled = previews.isEnabled
        Task {
            folders = previews.isEnabled ? await previews.folders() : []
            let running = previews.isEnabled ? await previews.ping() != nil : false
            status.stringValue = !previews.isEnabled ? "Off. Media madmd cannot read on its own shows placeholders." : running ? "On" : "On, but the helper is not responding."
            table.reloadData()
        }
    }

    @objc private func toggled() {
        if toggle.state == .on {
            Task {
                // Folders granted earlier are kept while the helper is off; only ask when there are none.
                if await previews.enable(), await previews.folders().isEmpty { await previews.allowFolder(startingAt: FullPreviews.home) }
                reload()
            }
        } else { previews.disable(); reload() }
    }

    @objc private func buttonPressed() {
        if buttons.selectedSegment == 1 {
            guard table.selectedRow >= 0 else { return }
            let path = folders[table.selectedRow].path
            Task { await previews.removeFolder(path) }
            return
        }
        let menu = NSMenu()
        for (title, path) in [("Home Folder", FullPreviews.home), ("Entire Disk", "/"), ("Temporary Files (/tmp)", "/private/tmp"), ("Other Folder…", FullPreviews.home)] {
            let item = NSMenuItem(title: title, action: #selector(add(_:)), keyEquivalent: ""); item.target = self; item.representedObject = path; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: buttons.bounds.height + 4), in: buttons)
    }

    @objc private func add(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        Task { await previews.allowFolder(startingAt: path) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { folders.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let folder = folders[row]
        let label = NSTextField(labelWithString: folder.available ? folder.path : "\(folder.path) (unavailable)")
        label.textColor = folder.available ? .labelColor : .secondaryLabelColor; label.lineBreakMode = .byTruncatingMiddle
        return label
    }
}
#endif
