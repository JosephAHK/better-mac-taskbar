#!/usr/bin/env bash
# Rebuild and restart Better Mac Taskbar when the built app is older than the
# sources. Runs as a Stop hook, so it must be a fast no-op on turns that did not
# touch any code.
set -uo pipefail

ROOT="/Users/joseph.raggiunti/Desktop/Better Mac Taskbar"
APP="$ROOT/build/Better Mac Taskbar.app"
BIN="$APP/Contents/MacOS/BetterMacTaskbar"
LOG="$ROOT/build/last-hook-build.log"

cd "$ROOT" || exit 0

# Skip the rebuild when nothing has changed since the last build. .DS_Store is
# pruned because Finder touches it constantly and would force a build every turn.
if [[ -f "$BIN" ]]; then
  changed=$(find Sources Resources build.sh \
    -name .DS_Store -prune -o \
    -type f -newer "$BIN" -print -quit 2>/dev/null)
  if [[ -z "$changed" ]]; then
    exit 0
  fi
fi

if ! ./build.sh >"$LOG" 2>&1; then
  printf '{"systemMessage": "Better Mac Taskbar: build FAILED — see build/last-hook-build.log"}\n'
  exit 0
fi

# pkill + open, not open alone: `open` on an already-running app just focuses the
# old process and the new binary never loads.
pkill -x BetterMacTaskbar 2>/dev/null
sleep 1
open "$APP"
printf '{"systemMessage": "Better Mac Taskbar: rebuilt and restarted"}\n'
