#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
report="$PWD/build/native-tests.json"
mkdir -p build
build/Build/Products/Release/madmd.app/Contents/MacOS/madmd --self-test "$report"
cat "$report"
