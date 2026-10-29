import AppKit
import UniformTypeIdentifiers

/// Which app opens Markdown files from Finder. Quick Look has no such API, so madmd can only point to its settings.
@MainActor enum MarkdownDefaults {
    /// The types Finder uses for these extensions; macOS confirms each change, so other aliases are left alone.
    private static var types: [UTType] {
        ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    static var handler: URL? { types.first.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) } }
    static var isDefault: Bool { handler.flatMap { Bundle(url: $0)?.bundleIdentifier } == Bundle.main.bundleIdentifier }

    static func makeDefault() async {
        // macOS asks the user to confirm and throws when they keep the current app; Settings shows the outcome either way.
        for type in types {
            guard (try? await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type)) != nil else { break }
        }
        NotificationCenter.default.post(name: .madmdDefaultsChanged, object: nil)
    }

    static func showQuickLookExtensions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }
}

extension Notification.Name { static let madmdDefaultsChanged = Notification.Name("madmdDefaultsChanged") }
