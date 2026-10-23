#!/usr/bin/env bash
# Builds Lar.app into build/. Pass --install to copy it to /Applications, save the LG token
# from $LAR_PAT in the keychain (if set) and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

APP=build/Lar.app
swift build "${SWIFT_FLAGS[@]}" -c release --product Lar
BIN="$(swift build "${SWIFT_FLAGS[@]}" -c release --show-bin-path)/Lar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Stamp the latest tag as the version, so a local build doesn't look outdated to the update check.
if VERSION="$(git describe --tags --abbrev=0 2>/dev/null)"; then
  VERSION="${VERSION#v}"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi
if [[ ! -f Resources/AppIcon.icns ]]; then
  scripts/make-icon.sh
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# A stable signature keeps the keychain's "Always Allow" across builds (an ad hoc one changes every time, and macOS
# asks again). LAR_SIGN_IDENTITY picks one; otherwise the first Apple Development / Developer ID certificate here.
IDENTITY="${LAR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk '/"(Apple Development|Developer ID Application):/ { print $2; exit }')}"
codesign --force --sign "${IDENTITY:--}" --timestamp=none "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Lar 2>/dev/null || true
  rm -rf /Applications/Lar.app
  cp -R "$APP" /Applications/Lar.app
  if [[ -n "${LAR_PAT:-}" ]]; then
    security add-generic-password -U -s com.coupled.lar -a thinq-pat \
      -l "Lar – LG ThinQ token" -w "$LAR_PAT" -T /Applications/Lar.app
    echo "Saved the LG token in the keychain"
  fi
  open /Applications/Lar.app
  echo "Installed /Applications/Lar.app"
fi
