import AppKit
import Combine
import SwiftUI

/// Observable bridge between SwiftUI settings UI and `TaskbarSettings` / system services.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var centerIcons: Bool {
        didSet {
            guard centerIcons != TaskbarSettings.shared.centerIcons else { return }
            TaskbarSettings.shared.centerIcons = centerIcons
        }
    }

    @Published var replaceDock: Bool {
        didSet {
            guard replaceDock != TaskbarSettings.shared.replaceDock else { return }
            TaskbarSettings.shared.replaceDock = replaceDock
            if replaceDock {
                DockManager.enableReplaceMode()
            } else {
                DockManager.restoreDock()
            }
        }
    }

    @Published var autoHideTaskbar: Bool {
        didSet {
            guard autoHideTaskbar != TaskbarSettings.shared.autoHideTaskbar else { return }
            TaskbarSettings.shared.autoHideTaskbar = autoHideTaskbar
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != LaunchAtLogin.isEnabled else { return }
            if !LaunchAtLogin.setEnabled(launchAtLogin) {
                launchAtLogin = LaunchAtLogin.isEnabled
            }
        }
    }

    @Published var hotkeyEnabled: Bool {
        didSet {
            guard hotkeyEnabled != TaskbarSettings.shared.startHotkeyEnabled else { return }
            if !hotkeyEnabled {
                HotkeyRecorder.shared.cancel()
            }
            TaskbarSettings.shared.startHotkeyEnabled = hotkeyEnabled
            AppLog.info("startHotkeyEnabled", ["enabled": hotkeyEnabled])
        }
    }

    @Published private(set) var hotkeyDisplay: String
    @Published private(set) var hiddenApps: [HiddenApp] = []
    @Published private(set) var accessibilityTrusted: Bool

    private var observers: [NSObjectProtocol] = []
    private var accessibilityTimer: Timer?

    struct HiddenApp: Identifiable, Equatable {
        let bundleID: String
        let name: String
        let icon: NSImage?
        var id: String { bundleID }

        static func == (lhs: HiddenApp, rhs: HiddenApp) -> Bool {
            lhs.bundleID == rhs.bundleID && lhs.name == rhs.name
        }
    }

    private init() {
        centerIcons = TaskbarSettings.shared.centerIcons
        replaceDock = TaskbarSettings.shared.replaceDock
        autoHideTaskbar = TaskbarSettings.shared.autoHideTaskbar
        launchAtLogin = LaunchAtLogin.isEnabled
        hotkeyEnabled = TaskbarSettings.shared.startHotkeyEnabled
        hotkeyDisplay = TaskbarSettings.shared.startMenuHotkey.displayString
        accessibilityTrusted = AccessibilityService.isTrusted(prompt: false)

        observers.append(NotificationCenter.default.addObserver(
            forName: .hiddenAppsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadHiddenApps()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .startMenuHotkeyChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadHotkey()
        })

        reloadHiddenApps()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        accessibilityTimer?.invalidate()
    }

    /// Re-sync values that outside code (or the system) can change while the window is closed.
    func refresh() {
        launchAtLogin = LaunchAtLogin.isEnabled
        hotkeyEnabled = TaskbarSettings.shared.startHotkeyEnabled
        centerIcons = TaskbarSettings.shared.centerIcons
        replaceDock = TaskbarSettings.shared.replaceDock
        autoHideTaskbar = TaskbarSettings.shared.autoHideTaskbar
        accessibilityTrusted = AccessibilityService.isTrusted(prompt: false)
        reloadHiddenApps()
        reloadHotkey()
    }

    /// Accessibility can be granted outside the app, so poll while the window is visible.
    func startWatchingAccessibility() {
        accessibilityTimer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let trusted = AccessibilityService.isTrusted(prompt: false)
            if trusted != self.accessibilityTrusted {
                self.accessibilityTrusted = trusted
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        accessibilityTimer = timer
    }

    func stopWatchingAccessibility() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
    }

    func show(bundleID: String) {
        HideManager.removeHidden(bundleID: bundleID)
    }

    func showAllHiddenApps() {
        for app in hiddenApps {
            HideManager.removeHidden(bundleID: app.bundleID)
        }
    }

    func resetHotkey() {
        HotkeyRecorder.shared.cancel()
        TaskbarSettings.shared.startMenuHotkey = .default
    }

    func openAccessibilitySettings() {
        if !accessibilityTrusted {
            _ = AccessibilityService.isTrusted(prompt: true)
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func reloadHotkey() {
        hotkeyEnabled = TaskbarSettings.shared.startHotkeyEnabled
        hotkeyDisplay = TaskbarSettings.shared.startMenuHotkey.displayString
    }

    private func reloadHiddenApps() {
        hiddenApps = TaskbarSettings.shared.hiddenBundleIDs.map { bundleID in
            HiddenApp(
                bundleID: bundleID,
                name: PinManager.appName(forBundleID: bundleID),
                icon: PinManager.icon(forBundleID: bundleID)
            )
        }
    }
}

/// Captures the next key combination — or a lone modifier — for the Start menu shortcut.
final class HotkeyRecorder: ObservableObject {
    static let shared = HotkeyRecorder()

    @Published private(set) var isRecording = false

    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var modifierKeyCode: UInt16?
    private var sawNonModifier = false

    private init() {}

    func toggle() {
        isRecording ? cancel() : start()
    }

    func start() {
        guard !isRecording else { return }
        isRecording = true
        modifierKeyCode = nil
        sawNonModifier = false
        StartHotkeyMonitor.shared.isSuspended = true

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event) ?? event
        }
    }

    func cancel() {
        guard isRecording || keyMonitor != nil || flagsMonitor != nil else { return }
        teardown()
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }

        if event.keyCode == 53 { // Escape cancels
            teardown()
            return nil
        }
        if StartMenuHotkey.modifierFlag(forKeyCode: event.keyCode) != nil {
            return nil
        }

        sawNonModifier = true
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        finish(StartMenuHotkey(keyCode: event.keyCode, modifierFlags: mods.rawValue, modifierOnly: false))
        return nil
    }

    private func handleFlagsChanged(_ event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }
        guard let flag = StartMenuHotkey.modifierFlag(forKeyCode: event.keyCode) else { return nil }

        if event.modifierFlags.contains(flag) {
            modifierKeyCode = event.keyCode
            sawNonModifier = false
            return nil
        }

        // Modifier released alone → treat as a modifier-only Start key (e.g. ⌘ / Windows).
        if let pressed = modifierKeyCode,
           StartMenuHotkey.isSameModifierKey(pressed, event.keyCode),
           !sawNonModifier {
            finish(StartMenuHotkey(keyCode: pressed, modifierFlags: flag.rawValue, modifierOnly: true))
        }
        return nil
    }

    private func finish(_ hotkey: StartMenuHotkey) {
        TaskbarSettings.shared.startMenuHotkey = hotkey
        teardown()
        AppLog.info("startMenuHotkey set", ["hotkey": hotkey.displayString])
    }

    private func teardown() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        isRecording = false
        modifierKeyCode = nil
        sawNonModifier = false
        StartHotkeyMonitor.shared.isSuspended = false
    }
}
