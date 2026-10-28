#!/bin/bash
# usage: test-native.sh [Release|AppStore]
set -euo pipefail
cd "$(dirname "$0")/.."
config="${1:-Release}"
if [[ "$config" == AppStore ]]; then
  # The sandboxed app can only write inside its own container.
  report="$HOME/Library/Containers/app.madmd.mac/Data/tmp/native-tests.json"
else
  report="$PWD/build/native-tests.json"
  mkdir -p build
fi
rm -f "$report"
status=0
"build/Build/Products/$config/madmd.app/Contents/MacOS/madmd" --self-test "$report" || status=$?
cat "$report"
exit "$status"
