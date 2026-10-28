#if APP_STORE
import AppKit
import ServiceManagement

let helperIdentifier = "H7B584W2D6.app.madmd.helper"

extension AppDelegate: NSMenuItemValidation {
    @objc func toggleFullPreviews(_ sender: NSMenuItem) {
        let service = SMAppService.loginItem(identifier: helperIdentifier)
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleFullPreviews(_:)) {
            menuItem.state = SMAppService.loginItem(identifier: helperIdentifier).status == .enabled ? .on : .off
        }
        return true
    }
}
#endif
