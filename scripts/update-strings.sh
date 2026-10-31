#!/usr/bin/env bash
# Brings Resources/Localizable.xcstrings up to date with the texts in the code: new ones are added (to translate),
# the ones no longer used are marked stale. Needs Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift build "${SWIFT_FLAGS[@]}" --scratch-path "$WORK/build" \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$WORK/strings"
# Texts of the extensions kept outside the repository (Sources/*/Private) stay out of the catalog.
private_names="$(find Sources -path '*/Private/*.swift' -exec basename {} .swift \; | paste -sd '|' -)"
args=()
while IFS= read -r file; do
  name="$(basename "$file" .stringsdata)"
  if [[ -n "$private_names" && "$name" =~ ^($private_names)$ ]]; then continue; fi
  args+=(--stringsdata "$file")
done < <(find "$WORK/strings" -name '*.stringsdata')
xcrun xcstringstool sync Resources/Localizable.xcstrings "${args[@]}"
echo "Updated Resources/Localizable.xcstrings"
