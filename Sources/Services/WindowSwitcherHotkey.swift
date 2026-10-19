import AppKit
import Carbon.HIToolbox

// Private but stable since 10.x: turns individual system shortcuts on and off. AltTab
// and Contexts switch the native ⌘Tab off the same way; there is no public API for it.
@_silgen_name("CGSSetSymbolicHotKeyEnabled")
private func BMTCGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ enabled: Bool) -> CGError

/// Symbolic hotkey ids for the native app switcher: ⌘Tab and ⌘⇧Tab. ⌘` is left alone.
private let nativeSwitcherHotKeys: [Int32] = [1, 2]

/// Drives the window switcher from ⌘Tab through a session event tap.
///
/// The native switcher is off exactly while the tap is installed, so a missing
/// Accessibility grant, a failed tap or the setting being off always leaves the
/// system ⌘Tab working.
@MainActor
final class WindowSwitcherHotkey {
    static let shared = WindowSwitcherHotkey()

    private enum KeyCode {
        static let tab: Int64 = 48
        static let escape: Int64 = 53
        static let left: Int64 = 123
        static let right: Int64 = 124
        static let down: Int64 = 125
        static let up: Int64 = 126
    }

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
    /// Runs only while ⌘ is held: secure input can switch on mid-hold, and a missed
    /// ⌘ release would leave the switcher open.
    private var commandHeldTimer: Timer?
    private var commandHeld = false
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
        if TaskbarSettings.shared.replaceCommandTab {
            installTap()
        } else {
            removeTap()
        }
    }

    func stop() {
        isStarted = false
        removeTap()
    }

    // MARK: - Tap lifecycle

    private func installTap() {
        guard tap == nil else { return }
        guard AccessibilityService.isTrusted(prompt: false) else {
            setNativeSwitcherEnabled(true)
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
            setNativeSwitcherEnabled(true)
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
        setNativeSwitcherEnabled(false)
        AppLog.info("window switcher on")
    }

    private func removeTap() {
        trustRetryTimer?.invalidate()
        trustRetryTimer = nil
        endCommandHold()
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
        setNativeSwitcherEnabled(true)
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

    private func handleFlagsChanged(_ flags: CGEventFlags) {
        let held = flags.contains(.maskCommand)
        if held, !commandHeld {
            commandHeld = true
            updateSecureInputFallback()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                // Added to the main run loop below.
                MainActor.assumeIsolated { self?.commandHeldTick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            commandHeldTimer = timer
        } else if !held, commandHeld {
            endCommandHold()
            WindowSwitcherController.shared.commit()
        }
    }

    private func commandHeldTick() {
        updateSecureInputFallback()
        // flagsChanged can be lost (the tap was briefly off, or secure input ate it).
        if !CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand) {
            endCommandHold()
            WindowSwitcherController.shared.commit()
        }
    }

    private func endCommandHold() {
        commandHeld = false
        commandHeldTimer?.invalidate()
        commandHeldTimer = nil
    }

    private func updateSecureInputFallback() {
        let secure = IsSecureEventInputEnabled()
        guard secure != secureInputFallback else { return }
        secureInputFallback = secure
        setNativeSwitcherEnabled(secure)
    }

    private func handleKeyDown(_ event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let switcher = WindowSwitcherController.shared
        let command = flags.contains(.maskCommand)
        let shift = flags.contains(.maskShift)

        if !switcher.isEngaged {
            guard keyCode == KeyCode.tab, command, !secureInputFallback,
                  !StartHotkeyMonitor.shared.isSuspended,
                  !flags.contains(.maskControl), !flags.contains(.maskAlternate) else { return false }
            if !commandHeld {
                // The ⌘ press itself was missed (the tap came up while it was held).
                handleFlagsChanged(flags)
            }
            switcher.open(reverse: shift)
            swallowedKeys.insert(keyCode)
            return true
        }

        guard command else {
            // ⌘ is up but its release never arrived; the state can't be trusted.
            endCommandHold()
            switcher.cancel()
            return false
        }
        switch keyCode {
        case KeyCode.tab: switcher.step(shift ? -1 : 1)
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
