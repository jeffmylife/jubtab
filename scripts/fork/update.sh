#!/bin/bash
# Fork: merge the latest upstream release, rebuild the unlocked/rebranded app, install it to /Applications.
# Usage: scripts/fork/update.sh [--force]   (--force rebuilds and reinstalls even when already current)
set -euo pipefail
cd "$(dirname "$0")/../.."

setting() { awk -F' = ' -v k="$1" '$1 == k { print $2 }' config/fork.xcconfig; }
NAME=$(setting PRODUCT_NAME)
BUNDLE_ID=$(setting PRODUCT_BUNDLE_IDENTIFIER)
APP="/Applications/$NAME.app"

notify() { osascript -e "display notification \"$1\" with title \"$NAME update\"" >/dev/null 2>&1 || true; }
fail() { echo "$(date '+%F %T') FAILED: $1" >&2; notify "Failed: $1"; exit 1; }
log() { echo "$(date '+%F %T') $1"; }

[ "$(git branch --show-current)" = master ] || fail "repo is not on master; skipped"
[ -z "$(git status --porcelain --untracked-files=no)" ] || fail "uncommitted changes in the repo; skipped"

git fetch -q upstream --tags
TAG=$(git describe --tags --abbrev=0 upstream/master)
VERSION=${TAG#v}
INSTALLED=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo none)
if [ "$VERSION" = "$INSTALLED" ] && [ "${1:-}" != --force ]; then
  log "$NAME $INSTALLED is current"
  exit 0
fi
log "updating $NAME $INSTALLED -> $VERSION"

# The unlock is only legitimate while upstream stays GPL; stop for a human if the licence ever changes.
git diff --quiet HEAD upstream/master -- LICENCE.md || fail "upstream changed LICENCE.md; review before merging"
git merge -q --no-edit upstream/master || { git merge --abort; fail "merge conflict with upstream $TAG; resolve by hand"; }
grep -q "if Self.forkUnlocked { return .pro }" src/pro/license/LicenseManager.swift || fail "unlock patch lost in merge"

BUILT=$(scripts/fork/build.sh Release CURRENT_PROJECT_VERSION="$VERSION") || fail "build failed (see build-fork/Release/build.log)"
codesign --verify --deep --strict "$BUILT" || fail "signature check failed"

osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
sleep 1
rm -rf "$APP.new"
ditto "$BUILT" "$APP.new"
rm -rf "$APP"
mv "$APP.new" "$APP"
open "$APP"

git push -q origin master || notify "Installed $VERSION, but git push failed"
log "installed $NAME $VERSION"
notify "Updated to $VERSION"
