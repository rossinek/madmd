#if APP_STORE
import AppKit

extension AppDelegate {
    /// The sandbox only grants files the user picked, so ask for one the app found on its own (e.g. a link).
    func requestAccess(to url: URL) {
        let panel = NSOpenPanel()
        panel.message = "madmd needs your permission to open “\(url.lastPathComponent)”."
        panel.prompt = "Open"
        panel.directoryURL = url
        panel.allowedContentTypes = [.plainText]; panel.canChooseDirectories = false
        if panel.runModal() == .OK, let picked = panel.url { openFile(picked) }
    }
}
#endif
