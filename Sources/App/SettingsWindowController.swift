import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private init() {
        let hosting = NSHostingController(rootView: SettingsRootView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Better Mac Taskbar Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 760, height: 520))
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.setActivationPolicy(.accessory)
        SettingsStore.shared.refresh()
        SettingsStore.shared.startWatchingAccessibility()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        HotkeyRecorder.shared.cancel()
        SettingsStore.shared.stopWatchingAccessibility()
    }
}
