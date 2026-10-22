import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var documents: [DocumentWindowController] = []
    private var terminating = false
    var active: DocumentWindowController? { documents.first { $0.window?.isKeyWindow == true } ?? documents.last }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenus()
        if let index = CommandLine.arguments.firstIndex(of: "--self-test"), CommandLine.arguments.count > index + 1 {
            Task { @MainActor in await SmokeTests.run(reportURL: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        if documents.isEmpty { newDocument(nil) }
    }
    func application(_ application: NSApplication, open urls: [URL]) { for url in urls { openFile(url) } }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !flag { newDocument(nil) }; return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task { @MainActor in
            for document in documents where !(await document.confirmClose()) {
                terminating = false; NSApp.reply(toApplicationShouldTerminate: false); return
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func openFile(_ url: URL) {
        if let existing = documents.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        Task { @MainActor in
            do {
                let file = try await Task.detached(priority: .userInitiated) { try MarkdownFile.read(url) }.value
                if let blank = documents.first(where: { $0.fileURL == nil && !$0.isDirty && $0.text.isEmpty }) {
                    blank.install(file); blank.window?.makeKeyAndOrderFront(nil)
                } else { add(DocumentWindowController(file: file)) }
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
            } catch { NSApp.presentError(error) }
        }
    }
    func add(_ controller: DocumentWindowController) {
        documents.append(controller)
        controller.onClose = { [weak self, weak controller] in self?.documents.removeAll { $0 === controller } }
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    @objc func newDocument(_ sender: Any?) { add(DocumentWindowController(file: nil)) }
    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.plainText]; panel.canChooseDirectories = false
        if panel.runModal() == .OK { for url in panel.urls { openFile(url) } }
    }
    @objc func saveDocument(_ sender: Any?) { active?.saveDocument(sender) }
    @objc func saveDocumentAs(_ sender: Any?) { active?.saveDocumentAs(sender) }
    @objc func preview(_ sender: Any?) { active?.selectMode(0) }
    @objc func edit(_ sender: Any?) { active?.selectMode(1) }
    @objc func toggleTheme(_ sender: Any?) { active?.toggleTheme(sender) }
    @objc func editorAction(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { active?.editorAction(id) } }

    private func makeMenus() {
        let bar = NSMenu()
        func menu(_ title: String) -> NSMenu { let item = NSMenuItem(); let sub = NSMenu(title: title); item.submenu = sub; bar.addItem(item); return sub }
        func item(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "", modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key); entry.keyEquivalentModifierMask = modifiers; entry.target = target; menu.addItem(entry)
        }
        let app = menu("madmd")
        item(app, "About madmd", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator()); item(app, "Hide madmd", #selector(NSApplication.hide(_:)), "h")
        item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option])
        item(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator()); item(app, "Quit madmd", #selector(NSApplication.terminate(_:)), "q")
        let file = menu("File")
        item(file, "New", #selector(newDocument(_:)), "n", target: self)
        item(file, "Open…", #selector(openDocument(_:)), "o", target: self)
        file.addItem(.separator()); item(file, "Close", #selector(NSWindow.performClose(_:)), "w")
        item(file, "Save", #selector(saveDocument(_:)), "s", target: self)
        item(file, "Save As…", #selector(saveDocumentAs(_:)), "s", modifiers: [.command, .shift], target: self)
        let edit = menu("Edit")
        func editor(_ title: String, _ id: String, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) {
            item(edit, title, #selector(editorAction(_:)), key, modifiers: modifiers, target: self); edit.items.last?.representedObject = id
        }
        editor("Undo", "undo", "z"); editor("Redo", "redo", "z", [.command, .shift])
        edit.addItem(.separator()); item(edit, "Cut", #selector(NSText.cut(_:)), "x"); item(edit, "Copy", #selector(NSText.copy(_:)), "c"); item(edit, "Paste", #selector(NSText.paste(_:)), "v"); item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator()); editor("Find…", "actions.find", "f"); editor("Replace…", "editor.action.startFindReplaceAction", "f", [.command, .option]); editor("Go to Line…", "editor.action.gotoLine", "l")
        let view = menu("View")
        item(view, "Preview", #selector(preview(_:)), "1", target: self); item(view, "Edit", #selector(self.edit(_:)), "2", target: self)
        view.addItem(.separator()); item(view, "Toggle Appearance", #selector(toggleTheme(_:)), "d", modifiers: [.command, .shift], target: self)
        let window = menu("Window")
        item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"); item(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        NSApp.windowsMenu = window; NSApp.mainMenu = bar
    }
}
