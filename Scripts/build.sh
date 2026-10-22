#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
npm run build:web
xcodegen generate
xcodebuild -project madmd.xcodeproj -scheme madmd -configuration Release -derivedDataPath build build "$@"
echo "Built: $PWD/build/Build/Products/Release/madmd.app"
