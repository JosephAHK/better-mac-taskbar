import AppKit
import Combine
import SwiftUI

/// Observable bridge between SwiftUI settings UI and `TaskbarSettings` / system services.
@MainActor
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
            Self.applyDockMode()
        }
    }

    @Published var buttonStyle: TaskbarButtonStyle {
        didSet {
            guard buttonStyle != TaskbarSettings.shared.buttonStyle else { return }
            TaskbarSettings.shared.buttonStyle = buttonStyle
        }
    }

    @Published var showWindowPreviews: Bool {
        didSet {
            guard showWindowPreviews != TaskbarSettings.shared.showWindowPreviews else { return }
            TaskbarSettings.shared.showWindowPreviews = showWindowPreviews
        }
    }

    @Published var windowPreviewDelay: Double {
        didSet {
            // Snap to 0.05 s without Slider.step, which draws macOS tick marks.
            let snapped = (windowPreviewDelay * 20).rounded() / 20
            let clamped = min(max(snapped, TaskbarSettings.windowPreviewDelayRange.lowerBound),
                              TaskbarSettings.windowPreviewDelayRange.upperBound)
            if abs(windowPreviewDelay - clamped) > 0.0001 {
                windowPreviewDelay = clamped
                return
            }
            guard abs(clamped - TaskbarSettings.shared.windowPreviewDelay) > 0.001 else { return }
            TaskbarSettings.shared.windowPreviewDelay = clamped
        }
    }

    @Published var previewThumbnailWidth: Double {
        didSet {
            // Snap to 10 pt without Slider.step, which draws macOS tick marks.
            let snapped = (previewThumbnailWidth / 10).rounded() * 10
            let clamped = min(max(snapped, TaskbarSettings.previewThumbnailWidthRange.lowerBound),
                              TaskbarSettings.previewThumbnailWidthRange.upperBound)
            if abs(previewThumbnailWidth - clamped) > 0.0001 {
                previewThumbnailWidth = clamped
                return
            }
            guard abs(clamped - TaskbarSettings.shared.previewThumbnailWidth) > 0.5 else { return }
            TaskbarSettings.shared.previewThumbnailWidth = clamped
        }
    }

    /// Set by code outside the window (the preview flyout's thumbnail hint) to open
    /// Settings on a particular page; the root view consumes and clears it.
    @Published var requestedPage: SettingsRootView.Section?

    @Published var autoHideTaskbar: Bool {
        didSet {
            guard autoHideTaskbar != TaskbarSettings.shared.autoHideTaskbar else { return }
            TaskbarSettings.shared.autoHideTaskbar = autoHideTaskbar
        }
    }

    @Published var autoHideRevealZone: Double {
        didSet {
            let value = Int(autoHideRevealZone.rounded())
            guard value != TaskbarSettings.shared.autoHideRevealZone else { return }
            TaskbarSettings.shared.autoHideRevealZone = value
        }
    }

    @Published var autoHideDelay: Double {
        didSet {
            // Snap to 0.05 s without using Slider.step (which draws macOS tick marks).
            let snapped = (autoHideDelay * 20).rounded() / 20
            let clamped = min(max(snapped, TaskbarSettings.autoHideDelayRange.lowerBound),
                              TaskbarSettings.autoHideDelayRange.upperBound)
            if abs(autoHideDelay - clamped) > 0.0001 {
                autoHideDelay = clamped
                return
            }
            guard abs(clamped - TaskbarSettings.shared.autoHideDelay) > 0.001 else { return }
            TaskbarSettings.shared.autoHideDelay = clamped
        }
    }

    @Published var revealDuration: Double {
        didSet {
            // Snap to 0.01 s without Slider.step, which draws macOS tick marks.
            let snapped = (revealDuration * 100).rounded() / 100
            let clamped = min(max(snapped, TaskbarSettings.revealDurationRange.lowerBound),
                              TaskbarSettings.revealDurationRange.upperBound)
            if abs(revealDuration - clamped) > 0.0001 {
                revealDuration = clamped
                return
            }
            guard abs(clamped - TaskbarSettings.shared.revealDuration) > 0.001 else { return }
            TaskbarSettings.shared.revealDuration = clamped
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != LaunchAtLogin.isRegistered else { return }
            if !LaunchAtLogin.setEnabled(launchAtLogin) {
                launchAtLogin = LaunchAtLogin.isRegistered
            }
            launchAtLoginNeedsApproval = LaunchAtLogin.needsApproval
        }
    }

    /// Registered but switched off in System Settings → Login Items, so the app
    /// will not actually launch at login until the user approves it there.
    @Published private(set) var launchAtLoginNeedsApproval: Bool

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

    @Published var replaceCommandTab: Bool {
        didSet {
            guard replaceCommandTab != TaskbarSettings.shared.replaceCommandTab else { return }
            if !replaceCommandTab {
                HotkeyRecorder.shared.cancel()
            }
            TaskbarSettings.shared.replaceCommandTab = replaceCommandTab
        }
    }

    @Published private(set) var hotkeyDisplay: String
    @Published private(set) var switcherShortcutDisplay: String
    @Published private(set) var switcherShortcutIsDefault: Bool

    @Published var switcherTheme: WindowSwitcherTheme {
        didSet {
            guard switcherTheme != TaskbarSettings.shared.windowSwitcherTheme else { return }
            TaskbarSettings.shared.windowSwitcherTheme = switcherTheme
        }
    }

    @Published var switcherThumbnailHeight: Double {
        didSet {
            // Snap to 10 pt without Slider.step, which draws macOS tick marks.
            let snapped = (switcherThumbnailHeight / 10).rounded() * 10
            let clamped = min(max(snapped, TaskbarSettings.switcherThumbnailHeightRange.lowerBound),
                              TaskbarSettings.switcherThumbnailHeightRange.upperBound)
            if abs(switcherThumbnailHeight - clamped) > 0.0001 {
                switcherThumbnailHeight = clamped
                return
            }
            guard abs(clamped - TaskbarSettings.shared.windowSwitcherThumbnailHeight) > 0.5 else { return }
            TaskbarSettings.shared.windowSwitcherThumbnailHeight = clamped
        }
    }

    @Published var switcherBackgroundOpacity: Double {
        didSet {
            // Snap to 5%.
            let snapped = (switcherBackgroundOpacity * 20).rounded() / 20
            let clamped = min(max(snapped, TaskbarSettings.switcherBackgroundOpacityRange.lowerBound),
                              TaskbarSettings.switcherBackgroundOpacityRange.upperBound)
            if abs(switcherBackgroundOpacity - clamped) > 0.0001 {
                switcherBackgroundOpacity = clamped
                return
            }
            guard abs(clamped - TaskbarSettings.shared.windowSwitcherBackgroundOpacity) > 0.001 else { return }
            TaskbarSettings.shared.windowSwitcherBackgroundOpacity = clamped
        }
    }

    @Published var switcherShowTitles: Bool {
        didSet {
            guard switcherShowTitles != TaskbarSettings.shared.windowSwitcherShowTitles else { return }
            TaskbarSettings.shared.windowSwitcherShowTitles = switcherShowTitles
        }
    }
    @Published private(set) var hiddenApps: [HiddenApp] = []
    @Published private(set) var accessibilityTrusted: Bool
    /// Screen Recording, which window preview thumbnails need. Only ever preflighted
    /// here, never requested, so reading it can't put up the system prompt.
    @Published private(set) var screenRecordingGranted: Bool

    /// Single-window capture (SCScreenshotManager) is macOS 14+; on 13 previews
    /// show titles only and the Screen Recording controls have nothing to offer.
    var windowThumbnailsSupported: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

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
        autoHideRevealZone = Double(TaskbarSettings.shared.autoHideRevealZone)
        autoHideDelay = TaskbarSettings.shared.autoHideDelay
        revealDuration = TaskbarSettings.shared.revealDuration
        buttonStyle = TaskbarSettings.shared.buttonStyle
        showWindowPreviews = TaskbarSettings.shared.showWindowPreviews
        windowPreviewDelay = TaskbarSettings.shared.windowPreviewDelay
        previewThumbnailWidth = TaskbarSettings.shared.previewThumbnailWidth
        launchAtLogin = LaunchAtLogin.isRegistered
        launchAtLoginNeedsApproval = LaunchAtLogin.needsApproval
        hotkeyEnabled = TaskbarSettings.shared.startHotkeyEnabled
        hotkeyDisplay = TaskbarSettings.shared.startMenuHotkey.displayString
        replaceCommandTab = TaskbarSettings.shared.replaceCommandTab
        switcherShortcutDisplay = TaskbarSettings.shared.windowSwitcherShortcut.displayString
        switcherShortcutIsDefault = TaskbarSettings.shared.windowSwitcherShortcut == .default
        switcherTheme = TaskbarSettings.shared.windowSwitcherTheme
        switcherThumbnailHeight = TaskbarSettings.shared.windowSwitcherThumbnailHeight
        switcherBackgroundOpacity = TaskbarSettings.shared.windowSwitcherBackgroundOpacity
        switcherShowTitles = TaskbarSettings.shared.windowSwitcherShowTitles
        accessibilityTrusted = AccessibilityService.isTrusted(prompt: false)
        screenRecordingGranted = CGPreflightScreenCaptureAccess()

        // `queue: .main` guarantees the main thread, which is what makes
        // assumeIsolated sound here.
        observers.append(NotificationCenter.default.addObserver(
            forName: .hiddenAppsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadHiddenApps() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .startMenuHotkeyChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadHotkey() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .windowSwitcherSettingChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadSwitcherShortcut() }
        })

        reloadHiddenApps()
    }

    /// Re-sync values that outside code (or the system) can change while the window is closed.
    func refresh() {
        refreshSystemStatus()
        hotkeyEnabled = TaskbarSettings.shared.startHotkeyEnabled
        replaceCommandTab = TaskbarSettings.shared.replaceCommandTab
        centerIcons = TaskbarSettings.shared.centerIcons
        replaceDock = TaskbarSettings.shared.replaceDock
        autoHideTaskbar = TaskbarSettings.shared.autoHideTaskbar
        autoHideRevealZone = Double(TaskbarSettings.shared.autoHideRevealZone)
        autoHideDelay = TaskbarSettings.shared.autoHideDelay
        revealDuration = TaskbarSettings.shared.revealDuration
        buttonStyle = TaskbarSettings.shared.buttonStyle
        showWindowPreviews = TaskbarSettings.shared.showWindowPreviews
        windowPreviewDelay = TaskbarSettings.shared.windowPreviewDelay
        previewThumbnailWidth = TaskbarSettings.shared.previewThumbnailWidth
        switcherTheme = TaskbarSettings.shared.windowSwitcherTheme
        switcherThumbnailHeight = TaskbarSettings.shared.windowSwitcherThumbnailHeight
        switcherBackgroundOpacity = TaskbarSettings.shared.windowSwitcherBackgroundOpacity
        switcherShowTitles = TaskbarSettings.shared.windowSwitcherShowTitles
        reloadHiddenApps()
        reloadHotkey()
        reloadSwitcherShortcut()
    }

    /// State owned by System Settings, which the user may have just changed there.
    /// Cheap enough to run every time the Settings window becomes key.
    func refreshSystemStatus() {
        launchAtLogin = LaunchAtLogin.isRegistered
        launchAtLoginNeedsApproval = LaunchAtLogin.needsApproval
        accessibilityTrusted = AccessibilityService.isTrusted(prompt: false)
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    /// Accessibility and Screen Recording can be granted outside the app, so poll
    /// while the window is visible.
    func startWatchingAccessibility() {
        accessibilityTimer?.invalidate()
        // Scheduled on the main run loop below, so the block always runs on main.
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let trusted = AccessibilityService.isTrusted(prompt: false)
                if trusted != self.accessibilityTrusted {
                    self.accessibilityTrusted = trusted
                }
                let screenRecording = CGPreflightScreenCaptureAccess()
                if screenRecording != self.screenRecordingGranted {
                    self.screenRecordingGranted = screenRecording
                }
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

    func resetSwitcherShortcut() {
        HotkeyRecorder.shared.cancel()
        TaskbarSettings.shared.windowSwitcherShortcut = .default
    }

    func openLoginItemsSettings() {
        LaunchAtLogin.openSystemSettings()
    }

    // MARK: Reset

    /// Resetting writes `TaskbarSettings` directly, which bypasses the `replaceDock`
    /// didSet — so apply the Dock side effect here, then re-sync.
    func resetToDefaults() {
        let alert = NSAlert()
        alert.messageText = "Reset all settings to their defaults?"
        alert.informativeText = "This also clears your pinned apps, hidden apps and taskbar order. Launch at login is not changed."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        HotkeyRecorder.shared.cancel()
        let replacedDock = TaskbarSettings.shared.replaceDock
        TaskbarSettings.shared.resetToDefaults()
        if TaskbarSettings.shared.replaceDock != replacedDock {
            Self.applyDockMode()
        }
        refresh()
        AppLog.info("settings reset to defaults")
    }

    private static func applyDockMode() {
        if TaskbarSettings.shared.replaceDock {
            DockManager.enableReplaceMode()
        } else {
            DockManager.restoreDock()
        }
    }

    func openAccessibilitySettings() {
        if !accessibilityTrusted {
            _ = AccessibilityService.isTrusted(prompt: true)
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The one place the app asks for Screen Recording, and only from the user's
    /// click. macOS shows its prompt the first time; once the user has answered,
    /// it shows nothing, which is what "Open Privacy Settings" is for.
    func requestScreenRecording() {
        let granted = CGRequestScreenCaptureAccess()
        AppLog.info("screen recording requested", ["granted": granted])
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func reloadHotkey() {
        hotkeyEnabled = TaskbarSettings.shared.startHotkeyEnabled
        hotkeyDisplay = TaskbarSettings.shared.startMenuHotkey.displayString
    }

    private func reloadSwitcherShortcut() {
        replaceCommandTab = TaskbarSettings.shared.replaceCommandTab
        let shortcut = TaskbarSettings.shared.windowSwitcherShortcut
        switcherShortcutDisplay = shortcut.displayString
        switcherShortcutIsDefault = shortcut == .default
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

/// Captures the next key combination for the Start menu shortcut (a lone modifier
/// too) or the window switcher shortcut.
@MainActor
final class HotkeyRecorder: ObservableObject {
    static let shared = HotkeyRecorder()

    enum Target {
        case startMenu
        case windowSwitcher
    }

    /// What is being recorded, or nil when idle.
    @Published private(set) var target: Target?
    /// Set when the last key pressed while recording was refused; recording
    /// continues so the user can simply try another combination.
    @Published private(set) var rejectionHint: String?

    var isRecording: Bool { target != nil }

    func isRecording(_ target: Target) -> Bool { self.target == target }

    func rejectionHint(for target: Target) -> String? {
        self.target == target ? rejectionHint : nil
    }

    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var modifierKeyCode: UInt16?
    private var sawNonModifier = false

    private init() {}

    func toggle(_ target: Target) {
        let wasRecording = isRecording(target)
        cancel()
        if !wasRecording { start(target) }
    }

    func start(_ target: Target) {
        guard !isRecording else { return }
        self.target = target
        modifierKeyCode = nil
        sawNonModifier = false
        StartHotkeyMonitor.shared.isSuspended = true
        if target == .windowSwitcher {
            WindowSwitcherHotkey.shared.setRecording(true)
        }

        // Local monitors are always called on the main thread.
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
        if target == .windowSwitcher {
            let mods = event.modifierFlags.intersection(WindowSwitcherShortcut.holdModifiers)
            guard !mods.isEmpty else {
                rejectionHint = "Hold ⌘, ⌥ or ⌃ with the key — letting go of it is what switches."
                return nil
            }
            finish(WindowSwitcherShortcut(keyCode: event.keyCode, modifierFlags: mods.rawValue))
            return nil
        }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard StartMenuHotkey.isAcceptableChord(keyCode: event.keyCode, modifierFlags: mods) else {
            rejectionHint = "Add ⌘, ⌥ or ⌃ — on its own, that key would stop typing in every app."
            return nil
        }
        finish(StartMenuHotkey(keyCode: event.keyCode, modifierFlags: mods.rawValue, modifierOnly: false))
        return nil
    }

    private func handleFlagsChanged(_ event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }
        // The switcher shortcut needs a key to press while the modifier is held.
        guard target == .startMenu,
              let flag = StartMenuHotkey.modifierFlag(forKeyCode: event.keyCode) else { return nil }

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

    private func finish(_ shortcut: WindowSwitcherShortcut) {
        // Back to normal first, so the tap re-arms with the new shortcut.
        teardown()
        TaskbarSettings.shared.windowSwitcherShortcut = shortcut
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
        let wasSwitcher = target == .windowSwitcher
        target = nil
        rejectionHint = nil
        modifierKeyCode = nil
        sawNonModifier = false
        StartHotkeyMonitor.shared.isSuspended = false
        if wasSwitcher {
            WindowSwitcherHotkey.shared.setRecording(false)
        }
    }
}
