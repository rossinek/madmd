# madmd

Select a Markdown file in Finder and press **Space** to preview it. Open it in madmd to edit. macOS 14 or later, Apple silicon and Intel.

https://github.com/user-attachments/assets/f158a328-18ac-4f5e-8c25-f28452f67d09

madmd shows tables, task lists, footnotes, alerts, code highlighting, LaTeX math, Mermaid diagrams, GeoJSON and TopoJSON maps, STL models, and images, video, and audio stored on your Mac. It has no account, analytics, or ads, and works offline except for images from the web and map backgrounds. See the [privacy policy](PRIVACY.md).

## Build and install

Requires Xcode with the macOS SDK, Node.js 22+, npm, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
npm ci
npm run build
bash Scripts/install.sh
```

This installs to `~/Applications/madmd.app`. An optional first argument selects another destination.

## Enable previews in Finder

1. Open **madmd** once.
2. Open **System Settings → General → Login Items & Extensions**. Under **Extensions**, click the info button next to **Quick Look**, enable **madmd**, and click **Done**. See Apple's [extension settings guide](https://support.apple.com/en-gb/guide/mac-help/-mtusr003/mac).
3. If another app handles Markdown previews, disable its Quick Look extension in the same list.
4. Select a `.md` file in Finder and press **Space**.

To open Markdown files in madmd by double-click, choose **madmd → Make madmd the Default for Markdown** (in App Store builds, also in **Settings**).

## Test

```sh
npm test
bash Scripts/test-native.sh
```

## License

[MIT](LICENSE) © 2026 Artur Rosa. Third-party dependencies retain their respective licenses; notices are included in the app's renderer bundle.
