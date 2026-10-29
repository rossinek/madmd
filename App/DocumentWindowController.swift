import AppKit
import WebKit
import UniformTypeIdentifiers

final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let renderer = MarkdownWebView()
    private(set) var text: String
    private var savedText: String
    private var file: MarkdownFile?
    var fileURL: URL? { file?.url }
    var isDirty: Bool { text != savedText }
    var onClose: (() -> Void)?
    private var closing = false
    private var closePending = false
    private var saving = false
    private var dark: Bool
    private let tabs = NSSegmentedControl(labels: ["Preview", "Edit"], trackingMode: .selectOne, target: nil, action: nil)
    private let themeButton = NSButton(image: NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "Toggle appearance")!, target: nil, action: nil)
    private let saveButton = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save")!, target: nil, action: nil)
    private var watch: DispatchSourceFileSystemObject?
    private var reloadTask: Task<Void, Never>?
    #if APP_STORE
    var deniedFolders = Set<String>()
    var accessBanner: NSView?
    #endif

    init(file: MarkdownFile?) {
        self.file = file; text = file?.text ?? ""; savedText = text
        dark = UserDefaults.standard.object(forKey: "darkMode") as? Bool ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self; window.minSize = NSSize(width: 480, height: 320); window.center()
        window.titlebarAppearsTransparent = true; window.toolbarStyle = .unified; window.contentView = renderer
        window.isReleasedWhenClosed = false; window.setFrameAutosaveName("Document")
        tabs.selectedSegment = 0; tabs.target = self; tabs.action = #selector(modeChanged(_:)); tabs.setAccessibilityLabel("Document mode")
        tabs.setWidth(78, forSegment: 0); tabs.setWidth(66, forSegment: 1)
        themeButton.target = self; themeButton.action = #selector(toggleTheme(_:)); themeButton.bezelStyle = .texturedRounded; themeButton.toolTip = "Toggle appearance"
        saveButton.target = self; saveButton.action = #selector(saveDocument(_:)); saveButton.bezelStyle = .texturedRounded; saveButton.toolTip = "Save (⌘S)"
        let toolbar = NSToolbar(identifier: "madmd.document"); toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [NSToolbarItem.Identifier("mode")]; window.toolbar = toolbar
        renderer.onEditSource = { [weak self] offset in
            self?.tabs.selectedSegment = 1; self?.renderer.revealSource(offset)
        }
        renderer.onChange = { [weak self] text in self?.text = text; self?.updateTitle() }
        renderer.onSave = { [weak self] in self?.saveDocument(nil) }
        renderer.onLink = { [weak self] url in self?.openLink(url) }
        renderer.onError = { [weak self] error in guard let window = self?.window else { return }; NSAlert(error: error).beginSheetModal(for: window) }
        #if APP_STORE
        renderer.onMediaDenied = { [weak self] path in self?.mediaDenied(path) }
        renderer.onAllowMedia = { [weak self] in self?.allowMediaAccess() }
        NotificationCenter.default.addObserver(self, selector: #selector(mediaAccessChanged), name: .madmdMediaAccessChanged, object: nil)
        #endif
        applyTheme(); renderer.load(text: text, fileURL: file?.url, theme: dark ? "dark" : "light"); updateTitle(); watchFile()
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: .madmdThemeChanged, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit { watch?.cancel(); reloadTask?.cancel(); NotificationCenter.default.removeObserver(self) }

    func install(_ file: MarkdownFile) {
        #if APP_STORE
        if file.url != self.file?.url { dismissAccessBanner() }
        #endif
        self.file = file; text = file.text; savedText = text
        renderer.load(text: text, fileURL: file.url, theme: dark ? "dark" : "light"); updateTitle(); watchFile()
    }
    private func updateTitle() {
        window?.title = file?.url.lastPathComponent ?? "Untitled"
        window?.representedURL = file?.url; window?.isDocumentEdited = isDirty
        saveButton.isEnabled = isDirty || file == nil
    }
    @objc private func modeChanged(_ sender: NSSegmentedControl) { renderer.setMode(sender.selectedSegment == 0 ? "preview" : "edit") }
    func selectMode(_ index: Int) { tabs.selectedSegment = index; modeChanged(tabs) }
    func find(_ action: NSTextFinder.Action) {
        if tabs.selectedSegment == 0 { renderer.find(action) }
        else {
            let id = action == .nextMatch ? "editor.action.nextMatchFindAction" : action == .previousMatch ? "editor.action.previousMatchFindAction" : "actions.find"
            renderer.action(id)
        }
    }
    func editorAction(_ id: String) { selectMode(1); renderer.action(id) }
    @objc func toggleTheme(_ sender: Any?) {
        UserDefaults.standard.set(!dark, forKey: "darkMode")
        NotificationCenter.default.post(name: .madmdThemeChanged, object: nil)
    }
    @objc private func themeDidChange() { dark = UserDefaults.standard.bool(forKey: "darkMode"); applyTheme() }
    private func applyTheme() { window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window?.backgroundColor = dark ? NSColor(srgbRed: 13/255, green: 17/255, blue: 23/255, alpha: 1) : .white; renderer.setTheme(dark ? "dark" : "light") }

    @objc func saveDocument(_ sender: Any?) { Task { @MainActor in _ = await save(as: false) } }
    @objc func saveDocumentAs(_ sender: Any?) { Task { @MainActor in _ = await save(as: true) } }
    @MainActor func save(as saveAs: Bool) async -> Bool {
        guard !saving, let window else { return false }
        saving = true; defer { saving = false }
        do {
            text = try await renderer.value(); updateTitle()
            var destination = file?.url
            if saveAs || destination == nil {
                let panel = NSSavePanel(); panel.nameFieldStringValue = file?.url.lastPathComponent ?? "Untitled.md"
                panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
                panel.canCreateDirectories = true
                guard await panel.beginSheetModal(for: window) == .OK else { return false }
                destination = panel.url
            }
            guard let destination else { return false }
            if let file, destination == file.url, (try? Data(contentsOf: destination)) != file.diskData {
                let alert = NSAlert(); alert.messageText = "The file changed on disk."; alert.informativeText = "Replace it with your changes?"
                alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Replace")
                guard await alert.beginSheetModal(for: window) == .alertSecondButtonReturn else { return false }
            }
            let snapshot = text
            let output = try file?.data(for: snapshot) ?? Data(snapshot.utf8)
            try await Task.detached(priority: .userInitiated) { try output.write(to: destination, options: .atomic) }.value
            self.file = MarkdownFile(url: destination, text: snapshot, diskData: output, encoding: file?.encoding ?? .utf8, bom: file?.bom ?? Data())
            savedText = snapshot; renderer.markSaved(); renderer.setDocumentURL(destination)
            updateTitle(); watchFile(); NSDocumentController.shared.noteNewRecentDocumentURL(destination)
            return true
        } catch { await NSAlert(error: error).beginSheetModal(for: window); return false }
    }

    @MainActor func confirmClose() async -> Bool {
        guard let window else { return true }
        do { text = try await renderer.value(); updateTitle() }
        catch { await NSAlert(error: error).beginSheetModal(for: window); return false }
        guard isDirty else { return true }
        let alert = closeAlert()
        switch await alert.beginSheetModal(for: window) {
        case .alertSecondButtonReturn: return await save(as: false)
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
    func closeAlert() -> NSAlert {
        let alert = NSAlert(); alert.messageText = "Save changes to “\(file?.url.lastPathComponent ?? "Untitled")”?"
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Save & Quit"); alert.addButton(withTitle: "Quit Anyway")
        alert.buttons[0].keyEquivalent = "\r"; alert.buttons[0].keyEquivalentModifierMask = []
        alert.buttons[2].hasDestructiveAction = true
        return alert
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closing { return true }
        guard !closePending else { return false }; closePending = true
        Task { @MainActor in
            let allowed = await confirmClose(); closePending = false
            if allowed { closing = true; close() }
        }
        return false
    }
    func windowWillClose(_ notification: Notification) { watch?.cancel(); reloadTask?.cancel(); onClose?() }
    func windowDidBecomeKey(_ notification: Notification) {
        if watch == nil { watchFile() }; refreshFromDisk()
        #if APP_STORE
        // Coming back from a permission prompt or Settings: media that was blocked may load now.
        if accessBanner != nil, FullPreviews.shared.isEnabled { mediaAccessChanged() }
        #endif
    }

    // Watches the file itself: a sandboxed app may only have access to the file, not its folder.
    // Editors that save by replacing the file leave the old descriptor behind, so follow the path again.
    private func watchFile(attempt: Int = 0) {
        watch?.cancel(); watch = nil
        guard let url = file?.url else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            if attempt < 20 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in if self?.watch == nil, self?.file?.url == url { self?.watchFile(attempt: attempt + 1) } } }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            if let source, !source.data.isDisjoint(with: [.rename, .delete]) { self?.watchFile() }
            self?.refreshFromDisk()
        }
        source.setCancelHandler { Darwin.close(fd) }; source.resume(); watch = source
        if attempt > 0 { refreshFromDisk() }
    }
    private func refreshFromDisk() {
        reloadTask?.cancel()
        guard !isDirty, !saving, let file else { return }
        reloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            guard let fresh = try? await Task.detached(priority: .utility, operation: { try MarkdownFile.read(file.url) }).value,
                  !Task.isCancelled, let self, !self.isDirty, !self.saving, self.file?.url == fresh.url, self.file?.diskData != fresh.diskData else { return }
            self.install(fresh)
        }
    }
    private func openLink(_ url: URL) {
        if ["https", "http", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
        else if let local = renderer.scheme.documentURL(for: url) {
            if ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn"].contains(local.pathExtension.lowercased()) { (NSApp.delegate as? AppDelegate)?.openFile(local) }
            // Never open or run other local files: only show them in Finder.
            else { NSWorkspace.shared.activateFileViewerSelecting([local]) }
        }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .init("mode"), .init("theme"), .init("save")] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .init("mode"), .flexibleSpace, .init("theme"), .init("save")] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id.rawValue {
        case "mode": item.view = tabs; item.label = "Document mode"
        case "theme": item.view = themeButton; item.label = "Appearance"
        case "save": item.view = saveButton; item.label = "Save"
        default: return nil
        }
        return item
    }
}
#if APP_STORE
extension DocumentWindowController {
    private static var hiddenToasts = Set<String>()

    /// Offers access to the folders holding media the sandbox and the helper could not read.
    func mediaDenied(_ path: String) {
        deniedFolders.insert((path as NSString).deletingLastPathComponent)
        guard accessBanner == nil, !Self.hiddenToasts.contains(fileURL?.path ?? "") else { return }
        let banner = AccessToast(message: "Some media in this document is in a folder madmd can’t read.", action: "Allow Access…", target: self, selector: #selector(allowMediaAccess))
        banner.onHide = { [weak self] in
            // Hidden until madmd quits; the placeholders still say what is missing.
            Self.hiddenToasts.insert(self?.fileURL?.path ?? ""); self?.accessBanner?.removeFromSuperview(); self?.accessBanner = nil
        }
        renderer.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: renderer.centerXAnchor),
            banner.topAnchor.constraint(equalTo: renderer.topAnchor, constant: 12),
            banner.widthAnchor.constraint(lessThanOrEqualTo: renderer.widthAnchor, constant: -32)
        ])
        accessBanner = banner
    }
    func dismissAccessBanner() {
        deniedFolders = []
        accessBanner?.removeFromSuperview(); accessBanner = nil
    }
    @objc func mediaAccessChanged() { dismissAccessBanner(); renderer.refresh() }
    @objc private func allowMediaAccess() {
        // Start the panel at the deepest folder that contains the document and every unreadable file.
        let folders = deniedFolders.union([fileURL?.deletingLastPathComponent().path].compactMap { $0 })
        let parts = folders.map { $0.split(separator: "/").map(String.init) }
        var common = parts.first ?? []
        for path in parts.dropFirst() { common = Array(zip(common, path).prefix { $0 == $1 }.map(\.0)) }
        Task { @MainActor in
            await FullPreviews.shared.allowFolder(startingAt: "/" + common.joined(separator: "/"))
        }
    }
}

/// A pill over the top of the document that warns about something the user can fix.
final class AccessToast: NSView {
    var onHide: (() -> Void)?

    init(message: String, action: String, target: AnyObject, selector: Selector) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false; wantsLayer = true
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")!)
        icon.contentTintColor = Self.foreground
        let label = NSTextField(labelWithString: message); label.textColor = Self.foreground; label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let button = PillButton(title: action, target: target, action: selector)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Hide")!, target: nil, action: #selector(hide))
        close.target = self; close.isBordered = false; close.contentTintColor = Self.foreground; close.toolTip = "Hide"
        close.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        let stack = NSStackView(views: [icon, label, button, close]); stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
        layer?.shadowOpacity = 0.18; layer?.shadowRadius = 8; layer?.shadowOffset = CGSize(width: 0, height: -2)
        setAccessibilityRole(.group); setAccessibilityLabel(message)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc private func hide() { onHide?() }

    // Primer's attention colors, solid so the document does not show through.
    static let foreground = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.82, green: 0.6, blue: 0.13, alpha: 1) : NSColor(srgbRed: 0.6, green: 0.4, blue: 0, alpha: 1) }
    private static let fill = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.15, green: 0.13, blue: 0.08, alpha: 1) : NSColor(srgbRed: 1, green: 0.97, blue: 0.77, alpha: 1) }
    private static let border = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.42, green: 0.31, blue: 0.07, alpha: 1) : NSColor(srgbRed: 0.83, green: 0.65, blue: 0.17, alpha: 1) }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Self.fill.cgColor; layer?.borderColor = Self.border.cgColor; layer?.shadowColor = NSColor.black.cgColor
        }
        layer?.borderWidth = 1; layer?.cornerRadius = bounds.height / 2
    }
    override func layout() { super.layout(); needsDisplay = true }
}

/// A fully rounded button in the toast's colors.
final class PillButton: NSButton {
    init(title: String, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.target = target; self.action = action; isBordered = false; wantsLayer = true
        attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium), .foregroundColor: AccessToast.foreground])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var intrinsicContentSize: NSSize { let size = super.intrinsicContentSize; return NSSize(width: size.width + 20, height: size.height + 6) }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = AccessToast.foreground.withAlphaComponent(isHighlighted ? 0.35 : 0.2).cgColor
        }
        layer?.cornerRadius = bounds.height / 2
    }
    override func layout() { super.layout(); needsDisplay = true }
}
#endif
extension Notification.Name { static let madmdThemeChanged = Notification.Name("madmdThemeChanged") }
