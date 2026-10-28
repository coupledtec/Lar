# Sourced by the other scripts. With only Command Line Tools, the macOS 27 SDK turns SwiftUI's @State into a
# macro whose plugin (SwiftUIMacros) ships only with Xcode, and SwiftPM's new build system fails to start
# ("Unknown error parsing property list"). So: the newest SDK that still builds, and the native build system.
CLT_SDKS=/Library/Developer/CommandLineTools/SDKs
if ! xcode-select -p | grep -q Xcode.app && [[ -z "${SDKROOT:-}" ]]; then
  for sdk in MacOSX26.5.sdk MacOSX26.sdk; do
    if [[ -d "$CLT_SDKS/$sdk" ]]; then export SDKROOT="$CLT_SDKS/$sdk"; break; fi
  done
fi
SWIFT_FLAGS=(--build-system native)
# Extensions kept outside the repository (Sources/*/Private, ignored by git) hook in where LAR_PRIVATE is set.
if [[ -d "$(dirname "${BASH_SOURCE[0]}")/../Sources/Lar/Private" ]]; then SWIFT_FLAGS+=(-Xswiftc -DLAR_PRIVATE); fi
