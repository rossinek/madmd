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

    /// After an update the old helper process keeps running its old code, so replace it. Its replies may not
    /// even arrive: once its bundle is replaced on disk, its signature no longer validates and XPC drops them.
    /// A helper that rejects the new app's connection cannot be asked to quit, so it is registered again instead.
    func refreshHelper() async {
        guard isEnabled, await ping() != Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return }
        if await !restartHelper() { _ = await reregister(alerting: false) }
    }

    /// A fresh process asks macOS for the protected folders inside the granted ones.
    @discardableResult func restartHelper() async -> Bool {
        let connection = HelperChannel.connection(); connection.resume()
        (connection.remoteObjectProxy as? HelperService)?.restart()
        try? await Task.sleep(for: .milliseconds(600)); connection.invalidate()
        return await waitForHelper()
    }

    /// Unregistering stops the helper's process, so registering again starts a new one.
    private func reregister(alerting: Bool = true) async -> Bool {
        try? await service.unregister()
        return await enable(alerting: alerting)
    }

    /// Alerts are for actions the user started; a check at launch stays quiet.
    func enable(alerting: Bool = true) async -> Bool {
        do { try service.register() } catch { if alerting { NSAlert(error: error).runModal() }; return false }
        onChange?()
        if service.status == .requiresApproval { if alerting { showApprovalNeeded() }; return false }
        let running = await waitForHelper()
        NotificationCenter.default.post(name: .madmdMediaAccessChanged, object: nil)
        return running
    }

    /// Offers to restart a helper that does not answer an action the user started. After a restart that did not help,
    /// it only says so, so the user never sees the same question twice in a row.
    func restartAfterNoResponse(offer: Bool = true) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Full Previews isn’t responding"
        guard offer else {
            alert.informativeText = "Restarting Full Previews didn’t help. Restart your Mac and try again."
            alert.runModal(); return false
        }
        alert.informativeText = "madmd can’t reach the helper that reads media for documents and Quick Look."
        alert.addButton(withTitle: "Restart Full Previews"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        return await restart()
    }

    /// Restarts the helper on the user's request and says so when that does not help.
    func restart() async -> Bool {
        if await reregister() { return true }
        if service.status != .requiresApproval { _ = await restartAfterNoResponse(offer: false) }
        return false
    }

    private func showApprovalNeeded() {
        let alert = NSAlert()
        alert.messageText = "Allow madmd in Login Items"
        alert.informativeText = "Full Previews needs madmd’s helper to run in the background. Turn on madmd in System Settings, then try again."
        alert.addButton(withTitle: "Open System Settings"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { SMAppService.openSystemSettingsLoginItems() }
    }

    func disable() {
        do { try service.unregister() } catch { NSAlert(error: error).runModal() }
        onChange?()
        NotificationCenter.default.post(name: .madmdMediaAccessChanged, object: nil)
    }

    func folders() async -> [(path: String, available: Bool)] {
        await HelperChannel.call { (helper, done: @escaping ([(path: String, available: Bool)]) -> Void) in
            helper.folders { paths, available in done(Array(zip(paths, available)).map { (path: $0.0, available: $0.1) }) }
        } ?? []
    }

    /// Enables the helper if needed, lets the user pick a folder in the helper's panel, and returns the chosen path.
    @discardableResult func allowFolder(startingAt path: String, retry: Bool = true) async -> String? {
        if !isEnabled {
            guard await enable() else {
                // A failed registration has already shown its own alert.
                if isEnabled, await restartAfterNoResponse(offer: retry) { return await allowFolder(startingAt: path, retry: false) }
                return nil
            }
        }
        // The panel may stay open for long, so a helper that hangs is caught by a quick ping first. No reply at all
        // means the helper is unreachable; a nil path means the user cancelled the panel.
        guard await ping() != nil, let chosen: String? = await HelperChannel.call(timeout: 3600, { helper, done in helper.addFolder(path) { done($0) } }) else {
            if await restartAfterNoResponse(offer: retry) { return await allowFolder(startingAt: path, retry: false) }
            return nil
        }
        guard let chosen else { return nil }
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
        let later = NSButton(title: "Not Now", target: nil, action: nil); later.keyEquivalent = "\u{1b}"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, later, enable])
        let stack = NSStackView(views: [title, body, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        body.preferredMaxLayoutWidth = 420
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Full Previews"; window.contentView = stack; window.isReleasedWhenClosed = false
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        stack.widthAnchor.constraint(equalToConstant: 468).isActive = true
        window.setContentSize(stack.fittingSize); window.center()
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
    private let defaultStatus = NSTextField(labelWithString: "")
    private let makeDefault = NSButton(title: "Make Default", target: nil, action: nil)

    init(previews: FullPreviews) {
        self.previews = previews
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"; window.isReleasedWhenClosed = false
        super.init(window: window)
        let note = NSTextField(wrappingLabelWithString: "Images, audio, video, and subtitles from these folders and their subfolders appear in documents and in Quick Look.")
        note.textColor = .secondaryLabelColor; note.font = .systemFont(ofSize: NSFont.smallSystemFontSize); note.preferredMaxLayoutWidth = 470
        let column = NSTableColumn(identifier: .init("path")); column.title = "Folders"; table.addTableColumn(column)
        table.headerView = nil; table.dataSource = self; table.delegate = self; table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        toggle.target = self; toggle.action = #selector(toggled)
        buttons.target = self; buttons.action = #selector(buttonPressed)
        status.textColor = .systemOrange; status.font = .systemFont(ofSize: NSFont.smallSystemFontSize); status.lineBreakMode = .byWordWrapping; status.preferredMaxLayoutWidth = 470
        // Markdown files: the Finder default can be read and changed; Quick Look's choice cannot.
        let separator = NSBox(); separator.boxType = .separator
        makeDefault.target = self; makeDefault.action = #selector(makeDefaultPressed)
        defaultStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let opening = NSStackView(views: [Self.heading("Open all Markdown files in madmd"), defaultStatus]); opening.orientation = .vertical; opening.alignment = .leading; opening.spacing = 4
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let openRow = NSStackView(views: [opening, spacer, makeDefault])
        let quickLook = NSTextField(wrappingLabelWithString: ""); quickLook.preferredMaxLayoutWidth = 470
        quickLook.attributedStringValue = Self.text([("When you select a file in Finder and ", false), ("press the Space bar", true), (", madmd shows a preview of it. ", false),
                                                     ("If another app’s preview appears instead", true), (", turn off that app in the Quick Look section of Extensions.", false)])
        let quickLookHeading = Self.heading("Quick Look in Finder")
        let extensions = NSButton(title: "Quick Look Extensions…", target: self, action: #selector(showExtensions))
        let stack = NSStackView(views: [toggle, status, note, scroll, buttons, separator, openRow, quickLookHeading, quickLook, extensions]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.setCustomSpacing(8, after: toggle); stack.setCustomSpacing(16, after: buttons); stack.setCustomSpacing(16, after: separator)
        stack.setCustomSpacing(20, after: openRow); stack.setCustomSpacing(4, after: quickLookHeading)
        window.contentView = stack
        for view in [scroll, separator, openRow] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true }
        stack.widthAnchor.constraint(equalToConstant: 518).isActive = true
        window.setContentSize(stack.fittingSize); window.center()
        previews.onChange = { [weak self] in self?.reload() }
        // Another app or Finder's Get Info can change the default while Settings is open.
        for name in [NSWindow.didBecomeKeyNotification, .madmdDefaultsChanged] {
            NotificationCenter.default.addObserver(self, selector: #selector(reloadDefaults), name: name, object: name == .madmdDefaultsChanged ? nil : window)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc private func reloadDefaults() {
        let isDefault = MarkdownDefaults.isDefault
        defaultStatus.stringValue = isDefault ? "madmd is the default app for Markdown files." : "madmd is not the default app for Markdown files."
        defaultStatus.textColor = isDefault ? .systemGreen : .secondaryLabelColor
        makeDefault.isHidden = isDefault
    }
    private static func heading(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold); return label
    }
    /// Secondary text with some parts in bold.
    private static func text(_ parts: [(String, bold: Bool)]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (string, bold) in parts {
            result.append(NSAttributedString(string: string, attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                                                                          .font: bold ? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold) : NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]))
        }
        return result
    }
    @objc private func makeDefaultPressed() { Task { await MarkdownDefaults.makeDefault() } }
    @objc private func showExtensions() { MarkdownDefaults.showQuickLookExtensions() }

    func reload() {
        reloadDefaults()
        toggle.state = previews.isEnabled ? .on : .off
        buttons.isEnabled = previews.isEnabled
        Task {
            folders = previews.isEnabled ? await previews.folders() : []
            let running = previews.isEnabled ? await previews.ping() != nil : false
            status.stringValue = !previews.isEnabled ? "Turn on Full Previews to see images, audio, and video in documents and Quick Look." : "Full Previews is not responding. Turn it off and on again."
            status.isHidden = previews.isEnabled && running
            table.reloadData()
            // Fit the window to the status line, keeping its top edge in place.
            if let window, let stack = window.contentView {
                var frame = window.frame; let fitted = window.frameRect(forContentRect: NSRect(origin: .zero, size: stack.fittingSize))
                frame.origin.y += frame.height - fitted.height; frame.size = fitted.size; window.setFrame(frame, display: true)
            }
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
