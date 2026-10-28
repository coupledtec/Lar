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
# The launchd agent that starts Lar at login and brings it back if it stops unexpectedly (StartAtLogin.swift).
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp Resources/LaunchAgents/com.coupled.lar.agent.plist "$APP/Contents/Library/LaunchAgents/"
# The other languages (Portuguese is the source): the String Catalog compiled into .lproj folders. The empty
# pt-BR.lproj tells macOS the app has Portuguese too. xcstringstool comes with Xcode.
mkdir -p "$APP/Contents/Resources/pt-BR.lproj"
if xcrun --find xcstringstool >/dev/null 2>&1; then
  xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$APP/Contents/Resources"
else
  echo "xcstringstool not found (needs Xcode): the app will be in Portuguese only"
fi
# A stable signature keeps the keychain's "Always Allow" across builds (an ad hoc one changes every time, and macOS
# asks again). LAR_SIGN_IDENTITY picks one; otherwise the first Apple Development / Developer ID certificate here.
IDENTITY="${LAR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk '/"(Apple Development|Developer ID Application):/ { print $2; exit }')}"
if [[ "$IDENTITY" == "Developer ID Application:"* ]]; then
  # For distribution: hardened runtime and a secure timestamp, as notarization requires.
  codesign --force --sign "$IDENTITY" --options runtime --timestamp --entitlements Resources/Lar.entitlements "$APP"
else
  codesign --force --sign "${IDENTITY:--}" --timestamp=none "$APP"
fi
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  # Asked to quit (a normal exit), so the launchd agent doesn't bring the old copy back mid-install.
  osascript -e 'if application id "com.coupled.lar" is running then tell application id "com.coupled.lar" to quit' \
    2>/dev/null || true
  sleep 1
  pkill -x Lar 2>/dev/null || true
  rm -rf /Applications/Lar.app
  cp -R "$APP" /Applications/Lar.app
  if [[ -n "${LAR_PAT:-}" ]]; then
    security add-generic-password -U -s com.coupled.lar -a thinq-pat \
      -l "Lar – LG ThinQ token" -w "$LAR_PAT" -T /Applications/Lar.app
    echo "Saved the LG token in the keychain"
  fi
  # Through the agent when it's registered, so the new copy is the one launchd brings back.
  launchctl kickstart "gui/$(id -u)/com.coupled.lar.agent" 2>/dev/null || open /Applications/Lar.app
  echo "Installed /Applications/Lar.app"
fi
