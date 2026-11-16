#!/usr/bin/env bash
# Builds Lar.app into build/. Pass --install to copy it to /Applications, save the LG token
# from $LAR_PAT in the keychain (if set) and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

APP=build/Lar.app
swift build "${SWIFT_FLAGS[@]}" -c release --product Lar
swift build "${SWIFT_FLAGS[@]}" -c release --product LarWidgets
BIN="$(swift build "${SWIFT_FLAGS[@]}" -c release --show-bin-path)/Lar"
WIDGETS_BIN="$(dirname "$BIN")/LarWidgets"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Stamp the latest tag as the version, so a local build doesn't look outdated to the update check. The highest one
# this commit has, not `git describe`'s: with two tags on one commit (a version only for the stores) it gave the older.
VERSION="$(git tag --merged HEAD --list 'v*' --sort=-v:refname 2>/dev/null | head -1)"
if [[ -n "$VERSION" ]]; then
  VERSION="${VERSION#v}"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi
# The widgets: an extension in PlugIns, with its own Info.plist and the same texts.
APPEX="$APP/Contents/PlugIns/LarWidgets.appex"
mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
cp "$WIDGETS_BIN" "$APPEX/Contents/MacOS/LarWidgets"
cp Resources/Widgets/Info.plist "$APPEX/Contents/Info.plist"
if [[ -n "$VERSION" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APPEX/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APPEX/Contents/Info.plist"
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
  # The permission requests (Info.plist's texts) in the same languages.
  xcrun xcstringstool compile Resources/InfoPlist.xcstrings --output-directory "$APP/Contents/Resources"
  xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$APPEX/Contents/Resources"
  mkdir -p "$APPEX/Contents/Resources/pt-BR.lproj"
else
  echo "xcstringstool not found (needs Xcode): the app will be in Portuguese only"
fi
# A stable signature keeps the keychain's "Always Allow" across builds (an ad hoc one changes every time, and macOS
# asks again). LAR_SIGN_IDENTITY picks one; otherwise the first Apple Development / Developer ID certificate here.
IDENTITY="${LAR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk '/"(Apple Development|Developer ID Application):/ { print $2; exit }')}"
# The folder the app shares with its widgets (an app group) is named after the certificate's team, read from the
# certificate itself: TEAMID.com.coupled.lar. Without a certificate the widgets only say to open the Lar.
TEAM=""
if [[ -n "$IDENTITY" ]]; then
  NAME="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' -v id="$IDENTITY" 'index($0, id) { print $2; exit }')"
  TEAM="$(security find-certificate -c "$NAME" -p 2>/dev/null | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
    | awk -F' = ' '/organizationalUnitName/ { print $2; exit }')"
fi
ENTITLEMENTS="$(mktemp -d)"
trap 'rm -rf "$ENTITLEMENTS"' EXIT
cp Resources/Lar.entitlements "$ENTITLEMENTS/app.plist"
cp Resources/Widgets/LarWidgets.entitlements "$ENTITLEMENTS/widgets.plist"
if [[ -n "$TEAM" ]]; then
  GROUP="$TEAM.com.coupled.lar"
  for plist in "$ENTITLEMENTS/app.plist" "$ENTITLEMENTS/widgets.plist"; do
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups array" -c "Add :com.apple.security.application-groups:0 string $GROUP" "$plist"
  done
  /usr/libexec/PlistBuddy -c "Add :LarAppGroup string $GROUP" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :LarAppGroup string $GROUP" "$APPEX/Contents/Info.plist"
fi
if [[ "$IDENTITY" == "Developer ID Application:"* ]]; then
  # For distribution: hardened runtime and a secure timestamp, as notarization requires. The extension first.
  codesign --force --sign "$IDENTITY" --options runtime --timestamp --entitlements "$ENTITLEMENTS/widgets.plist" "$APPEX"
  codesign --force --sign "$IDENTITY" --options runtime --timestamp --entitlements "$ENTITLEMENTS/app.plist" "$APP"
else
  codesign --force --sign "${IDENTITY:--}" --timestamp=none --entitlements "$ENTITLEMENTS/widgets.plist" "$APPEX"
  if [[ -n "$TEAM" ]]; then
    codesign --force --sign "$IDENTITY" --timestamp=none --entitlements "$ENTITLEMENTS/app.plist" "$APP"
  else
    codesign --force --sign "${IDENTITY:--}" --timestamp=none "$APP"
  fi
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
