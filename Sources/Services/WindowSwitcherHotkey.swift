import AppKit
import Carbon.HIToolbox

// Private but stable since 10.x: turns individual system shortcuts on and off. AltTab
// and Contexts switch the native ⌘Tab off the same way; there is no public API for it.
@_silgen_name("CGSSetSymbolicHotKeyEnabled")
private func BMTCGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ enabled: Bool) -> CGError

/// Symbolic hotkey ids for the native app switcher: ⌘Tab and ⌘⇧Tab. ⌘` is left alone.
private let nativeSwitcherHotKeys: [Int32] = [1, 2]

/// Drives the window switcher from its shortcut (⌘Tab unless changed) through a
/// session event tap.
///
/// The native switcher is off only while the tap is installed and the shortcut is
/// ⌘Tab, so a missing Accessibility grant, a failed tap, the setting being off or
/// a different shortcut always leaves the system ⌘Tab working.
@MainActor
final class WindowSwitcherHotkey {
    static let shared = WindowSwitcherHotkey()

    private enum KeyCode {
        static let escape: Int64 = 53
        static let left: Int64 = 123
        static let right: Int64 = 124
        static let down: Int64 = 125
        static let up: Int64 = 126
    }

    private var shortcut = TaskbarSettings.shared.windowSwitcherShortcut
    /// Settings is recording a new shortcut: every key passes through to it, and the
    /// native switcher is off so ⌘Tab can be recorded too.
    private var isRecording = false
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var isStarted = false
    /// Polls for the Accessibility grant while the setting is on but the tap can't be made.
    private var trustRetryTimer: Timer?
    private var nativeSwitcherEnabled: Bool?
    /// The trust retry keeps trying; the failure is logged once.
    private var loggedTapFailure = false
    /// Secure input (a password field) hides key events from taps, so ⌘Tab would do
    /// nothing at all; the native switcher stands in while it is on.
    private var secureInputFallback = false
    /// Runs only while the shortcut's modifiers are held: secure input can switch on
    /// mid-hold, and a missed release would leave the switcher open.
    private var modifiersHeldTimer: Timer?
    private var modifiersHeld = false
    /// Key-downs the switcher consumed; their key-ups are consumed too, so the app
    /// underneath never sees half a key press.
    private var swallowedKeys: Set<Int64> = []

    private init() {
        NotificationCenter.default.addObserver(forName: .windowSwitcherSettingChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isStarted else { return }
                self.start()
            }
        }
    }

    func start() {
        isStarted = true
        let shortcut = TaskbarSettings.shared.windowSwitcherShortcut
        if shortcut != self.shortcut {
            self.shortcut = shortcut
            endModifierHold()
            WindowSwitcherController.shared.cancel()
            AppLog.info("window switcher shortcut", ["shortcut": shortcut.displayString])
        }
        if TaskbarSettings.shared.replaceCommandTab {
            installTap()
        } else {
            removeTap()
        }
        updateNativeSwitcher()
    }

    /// Called by the Settings recorder around recording a switcher shortcut.
    func setRecording(_ recording: Bool) {
        guard recording != isRecording else { return }
        isRecording = recording
        if recording {
            endModifierHold()
            WindowSwitcherController.shared.cancel()
        }
        updateNativeSwitcher()
    }

    func stop() {
        isStarted = false
        removeTap()
    }

    // MARK: - Tap lifecycle

    private func installTap() {
        guard tap == nil else { return }
        guard AccessibilityService.isTrusted(prompt: false) else {
            updateNativeSwitcher()
            scheduleTrustRetry()
            return
        }
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: windowSwitcherTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            if !loggedTapFailure {
                loggedTapFailure = true
                AppLog.warn("window switcher event tap unavailable")
            }
            updateNativeSwitcher()
            scheduleTrustRetry()
            return
        }
        trustRetryTimer?.invalidate()
        trustRetryTimer = nil
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        tapSource = source
        loggedTapFailure = false
        secureInputFallback = false
        updateNativeSwitcher()
        AppLog.info("window switcher on", ["shortcut": shortcut.displayString])
    }

    private func removeTap() {
        trustRetryTimer?.invalidate()
        trustRetryTimer = nil
        endModifierHold()
        WindowSwitcherController.shared.cancel()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let tapSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes)
            }
            CFMachPortInvalidate(tap)
            AppLog.info("window switcher off")
        }
        tap = nil
        tapSource = nil
        swallowedKeys.removeAll()
        // Also covers a crash that left the native switcher disabled.
        updateNativeSwitcher()
    }

    private func scheduleTrustRetry() {
        guard trustRetryTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            // Added to the main run loop below.
            MainActor.assumeIsolated {
                guard let self, AccessibilityService.isTrusted(prompt: false) else { return }
                self.trustRetryTimer?.invalidate()
                self.trustRetryTimer = nil
                self.installTap()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustRetryTimer = timer
    }

    private func updateNativeSwitcher() {
        let replaced = tap != nil && shortcut.isCommandTab && !secureInputFallback
        setNativeSwitcherEnabled(!(replaced || isRecording))
    }

    private func setNativeSwitcherEnabled(_ enabled: Bool) {
        guard nativeSwitcherEnabled != enabled else { return }
        nativeSwitcherEnabled = enabled
        for hotKey in nativeSwitcherHotKeys {
            _ = BMTCGSSetSymbolicHotKeyEnabled(hotKey, enabled)
        }
    }

    // MARK: - Events

    /// Returns true to consume the event.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // Events went missing while it was off, ⌘ release included.
            WindowSwitcherController.shared.cancel()
            swallowedKeys.removeAll()
            return false
        case .flagsChanged:
            handleFlagsChanged(event.flags)
            return false
        case .keyDown:
            return handleKeyDown(event)
        case .keyUp:
            return swallowedKeys.remove(event.getIntegerValueField(.keyboardEventKeycode)) != nil
        default:
            return false
        }
    }

    /// The shortcut's modifiers as event-tap flags.
    private var holdFlags: CGEventFlags {
        let mods = shortcut.nsModifierFlags
        var flags: CGEventFlags = []
        if mods.contains(.command) { flags.insert(.maskCommand) }
        if mods.contains(.option) { flags.insert(.maskAlternate) }
        if mods.contains(.control) { flags.insert(.maskControl) }
        return flags
    }

    /// Letting go of any one of the shortcut's modifiers ends the hold.
    private func holdsModifiers(_ flags: CGEventFlags) -> Bool {
        flags.contains(holdFlags)
    }

    private func handleFlagsChanged(_ flags: CGEventFlags) {
        let held = holdsModifiers(flags)
        if held, !modifiersHeld {
            modifiersHeld = true
            updateSecureInputFallback()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                // Added to the main run loop below.
                MainActor.assumeIsolated { self?.modifiersHeldTick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            modifiersHeldTimer = timer
        } else if !held, modifiersHeld {
            endModifierHold()
            WindowSwitcherController.shared.commit()
        }
    }

    private func modifiersHeldTick() {
        updateSecureInputFallback()
        // flagsChanged can be lost (the tap was briefly off, or secure input ate it).
        if !holdsModifiers(CGEventSource.flagsState(.combinedSessionState)) {
            endModifierHold()
            WindowSwitcherController.shared.commit()
        }
    }

    private func endModifierHold() {
        modifiersHeld = false
        modifiersHeldTimer?.invalidate()
        modifiersHeldTimer = nil
    }

    private func updateSecureInputFallback() {
        let secure = IsSecureEventInputEnabled()
        guard secure != secureInputFallback else { return }
        secureInputFallback = secure
        updateNativeSwitcher()
    }

    private func handleKeyDown(_ event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let switcher = WindowSwitcherController.shared
        let shift = flags.contains(.maskShift)
        let trigger = Int64(shortcut.keyCode)

        if !switcher.isEngaged {
            // Exactly the shortcut's modifiers (⇧ aside): ⌘⌥Tab is not ⌘Tab.
            let held = flags.intersection([.maskCommand, .maskAlternate, .maskControl])
            guard keyCode == trigger, held == holdFlags, !secureInputFallback, !isRecording,
                  !StartHotkeyMonitor.shared.isSuspended else { return false }
            if !modifiersHeld {
                // The modifier press itself was missed (the tap came up while it was held).
                handleFlagsChanged(flags)
            }
            switcher.open(reverse: shift)
            swallowedKeys.insert(keyCode)
            return true
        }

        guard holdsModifiers(flags) else {
            // A modifier is up but its release never arrived; the state can't be trusted.
            endModifierHold()
            switcher.cancel()
            return false
        }
        switch keyCode {
        case trigger: switcher.step(shift ? -1 : 1)
        case KeyCode.left: switcher.step(-1)
        case KeyCode.right: switcher.step(1)
        case KeyCode.up: switcher.moveVertically(up: true)
        case KeyCode.down: switcher.moveVertically(up: false)
        case KeyCode.escape: switcher.cancel()
        default: return false
        }
        swallowedKeys.insert(keyCode)
        return true
    }
}

/// Runs on the main run loop, where the tap's source is installed.
private func windowSwitcherTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let consume = MainActor.assumeIsolated {
        Unmanaged<WindowSwitcherHotkey>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
    }
    return consume ? nil : Unmanaged.passUnretained(event)
}
