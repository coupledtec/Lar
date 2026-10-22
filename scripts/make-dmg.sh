#!/usr/bin/env bash
# Builds Lar.app and packs it into build/Lar-<version>.dmg: the app and a shortcut to /Applications, to drag across.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Lar.app/Contents/Info.plist)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R build/Lar.app "$STAGE/Lar.app"
ln -s /Applications "$STAGE/Aplicativos"
DMG="build/Lar-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Lar $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Built $DMG"
