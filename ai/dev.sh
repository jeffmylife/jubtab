#!/bin/bash
# Fork: build the rebranded Debug app ("JubTab Dev"), stop any running dev build, relaunch it.
# Logs go to /tmp/jubtab-dev.log (launched via `open` so TCC judges the app, not the terminal — see ai/run.sh).
set -e
cd "$(dirname "$0")/.."
APP=$(scripts/fork/build.sh Debug)
osascript -e 'quit app id "com.jeffmylife.jubtab-dev"' 2>/dev/null || true
sleep 0.3
open -n --stdout /tmp/jubtab-dev.log --stderr /tmp/jubtab-dev.log "$APP" --args --logs=debug
