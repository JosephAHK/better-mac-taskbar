import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private init() {
        let hosting = NSHostingController(rootView: SettingsRootView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Better Mac Taskbar Settings"
        // Not `titlebarAppearsTransparent`: it strips the toolbar's scroll-edge
        // background, so scrolled cards draw straight through the page title.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 760, height: 520))
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(page: SettingsRootView.Section? = nil) {
        SettingsStore.shared.refresh()
        SettingsStore.shared.startWatchingAccessibility()
        if let page {
            SettingsStore.shared.requestedPage = page
        }
        window?.makeKeyAndOrderFront(nil)
        // Not the macOS 14 `activate()`: that one is cooperative, and opened from the
        // menu bar or a non-activating flyout it can leave Settings behind the app
        // the user is in.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Login-item approval and Accessibility are granted in System Settings, so
    /// coming back from there is exactly when they change.
    func windowDidBecomeKey(_ notification: Notification) {
        SettingsStore.shared.refreshSystemStatus()
    }

    /// The recorder's monitors are local, so once the user switches away it would
    /// sit there with the global Start hotkey suspended and nothing to finish it.
    func windowDidResignKey(_ notification: Notification) {
        HotkeyRecorder.shared.cancel()
    }

    func windowWillClose(_ notification: Notification) {
        HotkeyRecorder.shared.cancel()
        SettingsStore.shared.stopWatchingAccessibility()
    }
}
