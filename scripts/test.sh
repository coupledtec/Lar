#!/usr/bin/env bash
# Runs the test suite. With only Command Line Tools installed, Swift Testing lives outside the
# default search paths, so point the compiler and linker at it.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
CLT=/Library/Developer/CommandLineTools/Library/Developer
if [[ -d "$CLT/Frameworks/Testing.framework" ]] && ! xcode-select -p | grep -q Xcode.app; then
  exec swift test "${SWIFT_FLAGS[@]}" \
    -Xswiftc -F -Xswiftc "$CLT/Frameworks" \
    -Xlinker -F -Xlinker "$CLT/Frameworks" \
    -Xlinker -rpath -Xlinker "$CLT/Frameworks" \
    -Xlinker -rpath -Xlinker "$CLT/usr/lib" "$@"
fi
exec swift test "${SWIFT_FLAGS[@]}" "$@"
