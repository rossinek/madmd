# madmd

A minimal macOS Markdown previewer, editor, and Quick Look extension. macOS 14 or later, Apple silicon and Intel.

The native AppKit window has Preview and Edit tabs, an appearance toggle, and Save. Edit uses Monaco with multiple cursors, find/replace, a command palette, folding, and familiar VS Code editor shortcuts. Files are only written by Save or Save As. Closing a modified file or quitting shows **Cancel** (default), **Save & Quit**, and **Quit Anyway**.

The app and Quick Look share a local renderer with GitHub Markdown styling, tables, task lists, autolinks, strikethrough, footnotes, emoji, alerts, HTML details, images, syntax highlighting, KaTeX math, Mermaid, GeoJSON, TopoJSON, and ASCII STL. GitHub account and repository service features are intentionally excluded. All rendering dependencies ship inside the app; remote images and OpenStreetMap background tiles require a connection. Local GeoJSON overlays render without map tiles.

## Build and run

Requires Xcode with the macOS SDK, Node.js 22+, npm, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
npm ci
npm run build
open build/Build/Products/Release/madmd.app Fixtures/showcase.md
```

`madmd.xcodeproj` is also checked in. `project.yml` is its source of truth. Run `npm run build:web` before the first Xcode build, or after changing web sources. The release build is a universal app with local ad hoc signing.

## Install Quick Look

```sh
bash Scripts/install.sh
```

This installs to `~/Applications/madmd.app` and registers the extension. An optional first argument selects another app destination. Open the installed app once, select a Markdown file in Finder, and press Space. macOS also lists the extension under System Settings → General → Login Items & Extensions → Quick Look. If another Markdown preview extension is enabled, disable that extension there to select madmd. The installer does not disable other apps' extensions.

Updates stage and verify the full bundle before replacing it, refresh the extension registration, and reset Quick Look's generator cache. Close an existing Quick Look panel before updating so Finder does not retain the old panel's cached result. The installer restores the previous app if replacement or registration fails.

The source build is suitable for local use. Distribution to other Macs needs your Developer ID, hardened runtime signing of both targets, and notarization. No signing credentials or provisioning profiles are included.

## Verify

```sh
npm test
bash Scripts/test-native.sh
```

The JavaScript tests cover syntax, sanitization, math layout, diagram source preservation, and a large document. The native suite opens real WebKit views and verifies the editor worker, both appearances, relative images, native dirty state, absence of autosaving, explicit atomic saves, undo, all four diagram formats, and Quick Look completion. It writes `build/native-tests.json`. Tests use temporary files. Finder preview selection should also be checked on the target Mac because the OS manages extension precedence.

## Implementation

- **App/** — native document windows, menus, manual saves, external-change protection, and file watching. UTF-8 and UTF-16 files preserve encoding and BOM; Monaco preserves the detected line-ending convention.
- **Shared/** — renderer bridge and a private resource scheme. Assets are local. Image and link paths are confined to the document folder, or the enclosing Git repository when available. Hidden files and symlink escapes are blocked. Quick Look has a read-only filesystem sandbox exception so referenced local images can load without a separate folder prompt. The scheme handler still enforces the document/repository boundary. macOS privacy controls remain in force. The app itself is not sandboxed.
- **QuickLook/** — sandboxed view-based preview extension. File reads happen off the main thread, and completion waits for the file's rendered content. Cancellation and reused-controller requests are isolated.
- **Web/** — sanitized GitHub-style renderer and lazy editor/diagram bundles. Quick Look's resource bundle excludes Monaco entirely. Mermaid uses strict security, untrusted scripts and active embeds are removed, and local file access is mediated by native code.

The application has no telemetry, CDN dependencies, or background server. Third-party license notices are packaged with the renderer.
