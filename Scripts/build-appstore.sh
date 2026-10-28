#!/bin/bash
# usage: build-appstore.sh [archive] [xcodebuild arguments...]
# Without "archive", builds the sandboxed App Store configuration signed for development.
# With "archive", also exports a package for App Store Connect (needs distribution profiles).
set -euo pipefail
cd "$(dirname "$0")/.."
mode=build
if [[ "${1:-}" == archive ]]; then mode=archive; shift; fi
npm run build:web
xcodegen generate
if [[ "$mode" == build ]]; then
  xcodebuild -project madmd.xcodeproj -scheme madmd -configuration AppStore -derivedDataPath build build "$@"
  echo "Built: $PWD/build/Build/Products/AppStore/madmd.app"
  exit 0
fi
archive="$PWD/build/AppStore/madmd.xcarchive"
export_dir="$PWD/build/AppStore/export"
options="$PWD/build/AppStore/ExportOptions.plist"
rm -rf "$archive" "$export_dir"
mkdir -p "$(dirname "$options")"
cat > "$options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>teamID</key><string>H7B584W2D6</string>
<key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
xcodebuild -project madmd.xcodeproj -scheme madmd -configuration AppStore -derivedDataPath build archive -archivePath "$archive" "$@"
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_dir" -exportOptionsPlist "$options" -allowProvisioningUpdates
echo "Exported: $export_dir"
