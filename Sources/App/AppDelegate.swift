import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.info("applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        WindowManager.shared.start()
        TaskbarPanelController.shared.show()

        ensureAccessibility()

        if !TaskbarSettings.shared.didConfigureLaunchAtLogin {
            TaskbarSettings.shared.didConfigureLaunchAtLogin = true
            _ = LaunchAtLogin.setEnabled(true)
        }
        AppLog.info("launchAtLogin", ["enabled": LaunchAtLogin.isEnabled])

        if TaskbarSettings.shared.replaceDock {
            DockManager.enableReplaceMode()
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.info("applicationWillTerminate")
        WindowManager.shared.stop()
        TaskbarPanelController.shared.hide()
        if TaskbarSettings.shared.replaceDock {
            DockManager.restoreDock()
        }
        AppLog.shutdown("applicationWillTerminate")
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
