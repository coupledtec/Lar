#!/usr/bin/env bash
# Builds Lar.app and packs it into build/Lar-<version>.dmg: the app and a shortcut to /Applications, to drag across.
# With a Developer ID certificate in the keychain the app and the image are signed with it, and with a notarytool
# profile (LAR_NOTARY_PROFILE, default "lar-notary"; see DEVELOPMENT.md) both are notarized and stapled, so the
# app opens without Gatekeeper's warning and can update itself.
set -euo pipefail
cd "$(dirname "$0")/.."
DEVELOPER_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application:/ { print $2; exit }')"
export LAR_SIGN_IDENTITY="${LAR_SIGN_IDENTITY:-$DEVELOPER_ID}"
PROFILE="${LAR_NOTARY_PROFILE:-lar-notary}"
notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait
}
can_notarize=false
if [[ -n "$DEVELOPER_ID" ]] && xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then can_notarize=true; fi

scripts/build-app.sh
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Lar.app/Contents/Info.plist)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
if $can_notarize; then
  ditto -c -k --keepParent build/Lar.app "$STAGE/Lar.zip"
  notarize "$STAGE/Lar.zip"
  xcrun stapler staple build/Lar.app
  rm "$STAGE/Lar.zip"
fi
cp -R build/Lar.app "$STAGE/Lar.app"
ln -s /Applications "$STAGE/Aplicativos"
DMG="build/Lar-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Lar $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
if [[ -n "$DEVELOPER_ID" ]]; then codesign --force --sign "$DEVELOPER_ID" --timestamp "$DMG"; fi
if $can_notarize; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
else
  echo "Not notarized (no Developer ID certificate or no notarytool profile \"$PROFILE\")."
fi
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Built $DMG"
