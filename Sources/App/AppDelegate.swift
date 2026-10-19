import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.info("applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.accessory)

        installMainMenu()
        setupStatusItem()
        WindowManager.shared.start()
        TaskbarPanelController.shared.show()
        StartHotkeyMonitor.shared.start()
        // With the setting off this re-enables the native ⌘Tab, in case a crash
        // left it disabled.
        WindowSwitcherHotkey.shared.start()

        ensureAccessibility()

        AppLog.info("launchAtLogin", [
            "registered": LaunchAtLogin.isRegistered,
            "needsApproval": LaunchAtLogin.needsApproval
        ])

        if TaskbarSettings.shared.replaceDock {
            DockManager.enableReplaceMode()
        } else if DockManager.hasSavedOriginals {
            // A previous run hid the Dock and never got to put it back (crash,
            // force-quit, or the setting was turned off while it was dying).
            AppLog.warn("Dock left hidden by a previous run — restoring")
            DockManager.restoreDock()
        }
        AppLog.info("settings", [
            "replaceDock": TaskbarSettings.shared.replaceDock,
            "autoHideTaskbar": TaskbarSettings.shared.autoHideTaskbar,
            "centerIcons": TaskbarSettings.shared.centerIcons,
            "barHeight": Int(TaskbarSettings.shared.barHeight)
        ])

        if !TaskbarSettings.shared.didPromptDock {
            TaskbarSettings.shared.didPromptDock = true
        }
        AppLog.info("application ready")
        // Dev aid: the status-menu item can't be driven from a script, so allow
        // launching straight into Settings for screenshots / manual checks.
        if ProcessInfo.processInfo.environment["BMT_OPEN_SETTINGS"] == "1" {
            SettingsWindowController.shared.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.info("applicationWillTerminate")
        StartHotkeyMonitor.shared.stop()
        // Puts the native ⌘Tab back.
        WindowSwitcherHotkey.shared.stop()
        WindowManager.shared.stop()
        TaskbarPanelController.shared.hide()
        // Unconditional: it is a no-op unless we hid the Dock, and it also drains
        // any apply still queued from a last-moment toggle. Blocking is the point —
        // the process exits as soon as this method returns.
        DockManager.restoreDock(waitUntilDone: true)
        AppLog.shutdown("applicationWillTerminate")
    }

    /// Accessory apps never show a menu bar, but AppKit still routes key
    /// equivalents through `mainMenu` — without one, ⌘W/⌘Q and the text-editing
    /// shortcuts do nothing in Settings or the Start menu search field.
    private func installMainMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: "Quit Better Mac Taskbar",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))

        let mainMenu = NSMenu()
        for submenu in [appMenu, editMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            if let appIcon = NSApp.applicationIconImage {
                let sized = NSImage(size: NSSize(width: 18, height: 18))
                sized.lockFocus()
                appIcon.draw(
                    in: NSRect(x: 0, y: 0, width: 18, height: 18),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
                sized.unlockFocus()
                sized.isTemplate = false
                button.image = sized
            } else {
                button.image = NSImage(systemSymbolName: "menubar.dock.rectangle", accessibilityDescription: "Better Mac Taskbar")
            }
            button.toolTip = "Better Mac Taskbar"
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Refresh Windows", action: #selector(refreshWindows), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Grant Accessibility…", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Better Mac Taskbar", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items {
            item.target = self
        }
        statusItem?.menu = menu
        menu.delegate = self
    }

    private func ensureAccessibility() {
        // Never auto-prompt on launch. Ad-hoc rebuilds make AXIsProcessTrusted false
        // even when the toggle still looks enabled — nagging every launch is useless.
        // User can grant via the status-menu item when they choose.
        let trusted = AccessibilityService.isTrusted(prompt: false)
        AppLog.info("accessibility", ["trusted": trusted])
        if trusted {
            WindowManager.shared.refresh()
        }
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func refreshWindows() {
        WindowManager.shared.refresh()
    }

    @objc private func openAccessibilitySettings() {
        // User-initiated only — safe to show the system prompt here.
        _ = AccessibilityService.isTrusted(prompt: true)
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ]
        for s in urls {
            if let url = URL(string: s) {
                NSWorkspace.shared.open(url)
                break
            }
        }
    }

    @objc private func quit() {
        AppLog.info("quit requested", ["source": "statusMenu"])
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if let item = menu.items.first(where: { $0.action == #selector(openAccessibilitySettings) }) {
            let trusted = AccessibilityService.isTrusted(prompt: false)
            item.title = trusted ? "Accessibility: On" : "Grant Accessibility…"
            item.isEnabled = !trusted
        }
    }
}
