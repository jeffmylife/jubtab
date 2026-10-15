#!/bin/bash
# Fork: build JubTab from a rebranded copy of the source.
# The repo keeps upstream's wording so upstream merges stay conflict-free; every "AltTab" is rewritten, and the
# Shiba icons swapped in, only in the staged copy under build-fork/ that actually gets compiled.
# Usage: scripts/fork/build.sh [Release|Debug] [extra xcodebuild settings...]   → prints the built .app path
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO=$PWD
CONFIG=${1:-Release}
shift || true
OUT="$REPO/build-fork/$CONFIG"
NEXT="$OUT/next"
STAGE="$OUT/src"

rm -rf "$NEXT"
mkdir -p "$NEXT" "$STAGE"
rsync -a --exclude .git --exclude /build-fork --exclude /DerivedData --exclude node_modules "$REPO/" "$NEXT/"

# Rebrand user-visible text. The identifiers this also renames (e.g. `showingAltTab`) are Swift-only, so renaming them
# consistently across every file is safe; preference keys and URLs other than the repository link don't contain "AltTab".
find "$NEXT/src" "$NEXT/resources/l10n" "$NEXT/Info.plist" "$NEXT/docs/contributors.md" -type f \( -name '*.swift' -o -name '*.strings' -o -name 'Info.plist' -o -name '*.md' \) -print0 \
  | xargs -0 perl -pi -e 's#https://github\.com/lwouis/alt-tab-macos#https://github.com/jeffmylife/jubtab#g; s/Alt-?Tab/JubTab/g; s/alt-tab-backend/license-backend/g'
# Fork-only sources (src/fork) are appended to App.swift so the Xcode project file never needs editing;
# #sourceLocation keeps compiler errors pointing at the real files.
find "$NEXT/src/fork" -name '*.swift' | sort | while read -r f; do
  printf '\n#sourceLocation(file: "%s", line: 1)\n' "$REPO/${f#$NEXT/}"
  cat "$f"
  printf '\n#sourceLocation()\n'
done >>"$NEXT/src/App.swift"
cp "$REPO/config/fork/app.png" "$NEXT/resources/icons/app/app.png"
cp "$REPO/config/fork"/menubar-*.pdf "$NEXT/resources/icons/menubar/"

# Sync by checksum so unchanged files keep their timestamps and incremental builds stay incremental.
rsync -a --checksum --delete "$NEXT/" "$STAGE/"
rm -rf "$NEXT"

xcodebuild -project "$STAGE/alt-tab-macos.xcodeproj" -scheme "$CONFIG" -configuration "$CONFIG" \
  -derivedDataPath "$OUT/DerivedData" "$@" build >"$OUT/build.log" 2>&1 \
  || { grep -E "error:" "$OUT/build.log" | sort -u | head -20 >&2; echo "build failed, see $OUT/build.log" >&2; exit 1; }
find "$OUT/DerivedData/Build/Products/$CONFIG" -maxdepth 1 -name '*.app' | head -1
