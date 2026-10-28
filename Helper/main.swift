import AppKit

// Login item that will read document resources for the sandboxed app and Quick Look.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
