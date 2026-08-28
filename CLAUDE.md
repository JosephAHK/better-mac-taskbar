# Better Mac Taskbar

Windows 10-style taskbar for macOS. Native Swift / AppKit accessory app (menu bar + bottom bar, no Dock required). No SwiftPM manifest — `build.sh` globs `Sources/**/*.swift` and compiles them directly, so a new file under `Sources/` is picked up with no registration step.

## Non-negotiable workflow

Every turn that changes code must end with all three of these done:

1. **Rebuild** — `./build.sh`. It compiles, bundles, codesigns, and installs to `~/Applications/Better Mac Taskbar.app`. Treat any `error:` in its output as blocking.
2. **Restart the running app** — the change is not live until the old process dies:
   ```bash
   pkill -x BetterMacTaskbar; sleep 1; open ~/Applications/"Better Mac Taskbar.app"
   ```
   `open` alone only focuses the already-running process; the new binary never loads.
3. **Commit and push to the default branch (`main`)** — `git push origin main`. Do not leave finished work sitting uncommitted in the working tree, and do not open a side branch for ordinary changes.

A `Stop` hook (`.claude/hooks/rebuild-restart.sh`) performs 1 and 2 automatically when sources are newer than the built binary. It does **not** commit or push — step 3 is always manual.

Verify a user-visible change against the running app before calling it done. `passesStandardWindow`-style claims should come from a real snapshot, not from reading the filter code.

## Editor-support caveat

SourceKit reports `Cannot find type 'WindowInfo' in scope` / `Cannot find 'AppLog' in scope` for almost every file, because there is no package manifest to tell it these files form one module. **These are false positives — ignore them.** `./build.sh` is the only authority on whether the code compiles.

## Diagnosing the window layer

`scripts/bmt-log` is the entry point. Read the log before theorising.

```bash
./scripts/bmt-log status    # running? what level? where's the log?
./scripts/bmt-log tail      # live follow, window/click/raise/WARN/ERROR only
./scripts/bmt-log all       # live follow, everything
./scripts/bmt-log snap      # full snapshot of every AX + CG window, now
./scripts/bmt-log verbose   # enable DEBUG, restart
./scripts/bmt-log quiet     # back to INFO, restart
```

`snap` (also `kill -USR1 <pid>`) is the ground truth for "why is there a button for an app with no windows" / "why is this window missing". It prints every AX window with its role, subrole, frame and `passesStandardWindow` verdict, plus every layer-0 CG window with `indexed=` and `rejectedBy=`.

Steady-state logging is change-only by design: `window set changed` fires once per real transition and `window dropped` once per newly-rejected window. `refresh()` runs on a poll timer *and* on every AX window event, so anything logged unconditionally per pass buries the log within minutes. Keep new hot-path logging change-gated (see `WindowDiagnostics`).

Logs live at `~/Library/Logs/BetterMacTaskbar/app.log`, rotating to `app.1.log` at 8MB. Details in `.cursor/rules/app-logs.mdc`.

## Window enumeration gotchas

These cost real debugging time; don't rediscover them.

- **`kAXWindowsAttribute` does not only contain windows.** Finder publishes its desktop there as a full-screen `AXScrollArea` with an empty subrole. `isStandardWindow` checks `kAXRoleAttribute == kAXWindowRole` first for exactly this reason.
- **`buildCGIndex` drops anything under 80×80** and passes `.excludeDesktopElements`, so an app can have AX windows and *zero* CG entries. When that happens `matchCGWindow` returns `nil`, and `onScreen` falls back to `!minimized` — i.e. a window that does not exist reports as on screen. The ghost-window guard in `enumerateViaAccessibility` covers this.
- Ghost-window guards are scoped to PIDs with **no** CG windows at all, never to a single failed per-window match. `matchCGWindow` legitimately fails on real windows (blank CG titles without Screen Recording, frames drifting mid-animation), and hiding a real window is a worse bug than tolerating one ghost.
- CG window **titles require Screen Recording permission**; they are frequently empty. Never treat a missing title as a missing window.
