#!/usr/bin/env bash
# Rebuild and restart Better Mac Taskbar when the app that actually runs is older
# than the sources. Runs as a Stop hook, so it must be a fast no-op on turns that
# did not touch any code.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUN_APP_RECORD="$ROOT/build/.run-app-path"
LOG="$ROOT/build/last-hook-build.log"

cd "$ROOT" || exit 0

# build.sh records where it installed the app (/Applications, ~/Applications, or
# build/ as a fallback). Compare against and launch that copy — the build/ bundle
# is only an intermediate, and opening it would start a second app with the same
# bundle id.
app="$(cat "$RUN_APP_RECORD" 2>/dev/null)"
bin="$app/Contents/MacOS/BetterMacTaskbar"

# Skip the rebuild when nothing has changed since the last build. .DS_Store is
# pruned because Finder touches it constantly and would force a build every turn.
if [[ -n "$app" && -f "$bin" ]]; then
  changed=$(find Sources Resources build.sh \
    -name .DS_Store -prune -o \
    -type f -newer "$bin" -print -quit 2>/dev/null)
  if [[ -z "$changed" ]]; then
    exit 0
  fi
fi

mkdir -p "$ROOT/build"
if ! ./build.sh >"$LOG" 2>&1; then
  printf '{"systemMessage": "Better Mac Taskbar: build FAILED — see build/last-hook-build.log"}\n'
  exit 0
fi
app="$(cat "$RUN_APP_RECORD" 2>/dev/null)"

# pkill + open, not open alone: `open` on an already-running app just focuses the
# old process and the new binary never loads. SIGTERM is a graceful quit (it
# restores the Dock first), so wait for the exit instead of guessing a sleep.
pkill -x BetterMacTaskbar 2>/dev/null
for _ in {1..50}; do
  pgrep -x BetterMacTaskbar >/dev/null || break
  sleep 0.1
done
open "$app"
printf '{"systemMessage": "Better Mac Taskbar: rebuilt and restarted"}\n'
