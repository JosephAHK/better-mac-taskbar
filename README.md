# Better Mac Taskbar

A Windows 10–style taskbar for macOS. Native Swift / AppKit accessory app (menu bar + bottom bar, no Dock required).

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5-orange)

## Features

- Frosted-glass bottom taskbar
- Per-window icons (Chrome / multi-window apps show separately)
- Center or left-aligned icons
- Start menu with pinned apps and type-to-search across installed apps
- Clock, tray, Show Desktop
- Right-click: Close, Minimize, Pin, Hide, New window, Quit
- Middle-click closes a window
- Optional Dock replacement (Dock fully hidden while running; restored on quit)
- Optional auto-hide taskbar
- Launch at login
- App log file for diagnosing unexpected quits (`~/Library/Logs/BetterMacTaskbar/app.log`)

## Requirements

- macOS 13 or later
- Apple Silicon (arm64) — build script targets `arm64-apple-macosx`
- Xcode Command Line Tools (`xcode-select --install`)

## Build & run

```bash
git clone https://github.com/JosephAHK/better-mac-taskbar.git
cd better-mac-taskbar
./build.sh
open "build/Better Mac Taskbar.app"
```

`build.sh` compiles all Swift sources, packages an `.app` bundle, and codesigns it (Apple Development identity if available, otherwise a stable local identity, otherwise ad-hoc).

## Permissions

Grant **Accessibility** in **System Settings → Privacy & Security → Accessibility**.

Use the menu bar icon → **Grant Accessibility…** if needed. Without Accessibility, the taskbar falls back to one icon per app instead of per window.

After a rebuild, macOS may keep the Accessibility toggle on but stop trusting the new binary — turn it **off then on** for Better Mac Taskbar, then choose **Refresh Windows**.

Automation permission may also be requested the first time the app raises or minimizes scriptable windows (e.g. Chrome).

## Settings

Menu bar icon → **Settings…**, or Start → Settings:

- Center taskbar icons
- Hide Dock (use taskbar instead)
- Automatically hide the taskbar
- Launch at login

## Project layout

```
Sources/          Swift / AppKit source
Resources/        Info.plist, app icon
build.sh          Compile, package, sign
build/            Generated .app (gitignored)
```

## Logs

Runtime diagnostics are written to:

```
~/Library/Logs/BetterMacTaskbar/app.log
```

Useful when the app disappears after a rebuild (`pkill` + relaunch) or exits unexpectedly.

## License

MIT
