#!/bin/bash
# Fork: build the Debug app, stop both the installed AltTab and any running dev build, relaunch the dev build.
# Logs go to /tmp/alttab-dev.log (launched via `open` so TCC judges the app, not the terminal — see ai/run.sh).
set -e
cd "$(dirname "$0")/.."
bash ai/build.sh 2>&1 | grep -E "error:|BUILD" || true
osascript -e 'quit app id "com.lwouis.alt-tab-macos"' 2>/dev/null || true
pkill -f "alttab-fork/DerivedData/Build/Products/Debug/AltTab.app" 2>/dev/null || true
sleep 0.3
open -n --stdout /tmp/alttab-dev.log --stderr /tmp/alttab-dev.log "$PWD/DerivedData/Build/Products/Debug/AltTab.app" --args --logs=debug
