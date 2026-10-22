#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_app="$PWD/build/Build/Products/Release/madmd.app"
destination="${1:-$HOME/Applications/madmd.app}"
if [[ "$destination" != *.app || "$destination" == "$source_app" ]]; then
  echo 'Choose a separate destination ending in .app.' >&2
  exit 1
fi
if [[ ! -d "$source_app" ]]; then
  echo 'Build first: npm run build' >&2
  exit 1
fi
if [[ -e "$destination" ]]; then
  existing_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist" 2>/dev/null || true)
  if [[ "$existing_id" != app.madmd.mac ]]; then
    echo "Refusing to replace a different app: $destination" >&2
    exit 1
  fi
fi
mkdir -p "$(dirname "$destination")"
staging=$(mktemp -d "$(dirname "$destination")/.madmd-install.XXXXXX")
replacement_started=false
committed=false
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
cleanup() {
  result=$?
  if [[ "$committed" == false && ( "$replacement_started" == true || -d "$staging/previous.app" ) ]]; then
    # Only our staged replacement can be at this path after replacement starts.
    rm -rf "$destination"
    if [[ -d "$staging/previous.app" ]]; then
      mv "$staging/previous.app" "$destination"
      "$lsregister" -f "$destination" || true
      pluginkit -a "$destination/Contents/PlugIns/madmdQuickLook.appex" || true
    fi
  fi
  rm -rf "$staging"
  exit "$result"
}
trap cleanup EXIT
ditto "$source_app" "$staging/new.app"
codesign --verify --deep --strict "$staging/new.app"
if [[ -d "$destination" ]]; then
  pluginkit -r "$destination/Contents/PlugIns/madmdQuickLook.appex" || true
  "$lsregister" -u "$destination" || true
  mv "$destination" "$staging/previous.app"
fi
replacement_started=true
# Renaming a complete, verified bundle avoids changing an extension's executable
# and resources underneath a running Quick Look process.
mv "$staging/new.app" "$destination"
pluginkit -r "$source_app/Contents/PlugIns/madmdQuickLook.appex" || true
"$lsregister" -u "$source_app" || true
"$lsregister" -f "$destination"
pluginkit -a "$destination/Contents/PlugIns/madmdQuickLook.appex"
pluginkit -e use -i app.madmd.mac.quicklook
qlmanage -r
committed=true
echo "Installed: $destination"
