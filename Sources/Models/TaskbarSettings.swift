import Foundation
import AppKit

/// Keyboard shortcut that toggles the Start menu.
struct StartMenuHotkey: Equatable {
    /// Hardware key code. For modifier-only shortcuts this is the modifier key itself.
    var keyCode: UInt16
    /// Device-independent modifier flags that must be held (command/option/control/shift).
    var modifierFlags: UInt
    /// True when the shortcut is a modifier pressed alone (e.g. Windows / ⌘).
    var modifierOnly: Bool

    /// Default: left Command / Windows key alone.
    static let `default` = StartMenuHotkey(
        keyCode: 55,
        modifierFlags: NSEvent.ModifierFlags.command.rawValue,
        modifierOnly: true
    )

    var nsModifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlags).intersection([.command, .option, .control, .shift])
    }

    var displayString: String {
        if modifierOnly {
            return Self.modifierSymbol(forKeyCode: keyCode) ?? "⌘"
        }
        var parts: [String] = []
        let mods = nsModifierFlags
        if mods.contains(.control) { parts.append("⌃") }
        if mods.contains(.option) { parts.append("⌥") }
        if mods.contains(.shift) { parts.append("⇧") }
        if mods.contains(.command) { parts.append("⌘") }
        parts.append(Self.keyDisplayName(keyCode))
        return parts.joined()
    }

    static func modifierSymbol(forKeyCode keyCode: UInt16) -> String? {
        switch keyCode {
        case 54, 55: return "⌘"
        case 58, 61: return "⌥"
        case 59, 62: return "⌃"
        case 56, 60: return "⇧"
        case 63: return "fn"
        default: return nil
        }
    }

    static func modifierFlag(forKeyCode keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: return .command
        case 58, 61: return .option
        case 59, 62: return .control
        case 56, 60: return .shift
        case 63: return .function
        default: return nil
        }
    }

    /// Left/right variants of the same modifier count as a match.
    static func isSameModifierKey(_ a: UInt16, _ b: UInt16) -> Bool {
        guard let fa = modifierFlag(forKeyCode: a), let fb = modifierFlag(forKeyCode: b) else {
            return a == b
        }
        return fa == fb
    }

    static func keyDisplayName(_ keyCode: UInt16) -> String {
        let special: [UInt16: String] = [
            36: "Return",
            48: "Tab",
            49: "Space",
            51: "Delete",
            53: "Esc",
            117: "Fwd Del",
            123: "←",
            124: "→",
            125: "↓",
            126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4",
            96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12"
        ]
        if let name = special[keyCode] { return name }
        if let symbol = modifierSymbol(forKeyCode: keyCode) { return symbol }

        let source = CGEventSource(stateID: .hidSystemState)
        if let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true) {
            event.flags = []
            if let nsEvent = NSEvent(cgEvent: event),
               let chars = nsEvent.charactersIgnoringModifiers,
               !chars.isEmpty {
                return chars.uppercased()
            }
        }
        return "Key \(keyCode)"
    }
}

final class TaskbarSettings {
    static let shared = TaskbarSettings()

    /// Fixed taskbar height (slightly smaller than the old 52px default).
    static let barHeight: CGFloat = 56

    private let defaults = UserDefaults.standard
    private enum Key {
        static let centerIcons = "centerIcons"
        static let replaceDock = "replaceDock"
        static let autoHideTaskbar = "autoHideTaskbar"
        static let pinnedBundleIDs = "pinnedBundleIDs"
        static let hiddenBundleIDs = "hiddenBundleIDs"
        static let taskbarOrder = "taskbarOrder"
        static let didPromptDock = "didPromptDock"
        static let didDismissAccessibilityPrompt = "didDismissAccessibilityPrompt"
        static let didConfigureLaunchAtLogin = "didConfigureLaunchAtLogin"
        static let startHotkeyKeyCode = "startHotkeyKeyCode"
        static let startHotkeyModifiers = "startHotkeyModifiers"
        static let startHotkeyModifierOnly = "startHotkeyModifierOnly"
    }

    var centerIcons: Bool {
        get { defaults.object(forKey: Key.centerIcons) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.centerIcons)
            NotificationCenter.default.post(name: .taskbarSettingsChanged, object: nil)
        }
    }

    var barHeight: CGFloat { Self.barHeight }

    var replaceDock: Bool {
        get { defaults.object(forKey: Key.replaceDock) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.replaceDock)
            NotificationCenter.default.post(name: .taskbarSettingsChanged, object: nil)
        }
    }

    /// Slide the taskbar off-screen until the cursor hits the bottom edge.
    var autoHideTaskbar: Bool {
        get { defaults.object(forKey: Key.autoHideTaskbar) as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: Key.autoHideTaskbar)
            NotificationCenter.default.post(name: .taskbarSettingsChanged, object: nil)
        }
    }

    var pinnedBundleIDs: [String] {
        get { defaults.stringArray(forKey: Key.pinnedBundleIDs) ?? [] }
        set {
            defaults.set(newValue, forKey: Key.pinnedBundleIDs)
            NotificationCenter.default.post(name: .pinnedAppsChanged, object: nil)
        }
    }

    /// Apps that never appear on the taskbar (still launchable; managed via context menu / Settings).
    var hiddenBundleIDs: [String] {
        get { defaults.stringArray(forKey: Key.hiddenBundleIDs) ?? [] }
        set {
            defaults.set(newValue, forKey: Key.hiddenBundleIDs)
            NotificationCenter.default.post(name: .hiddenAppsChanged, object: nil)
        }
    }

    /// Left-to-right order of taskbar icons (bundle IDs, or window IDs when no bundle ID).
    var taskbarOrder: [String] {
        get { defaults.stringArray(forKey: Key.taskbarOrder) ?? [] }
        set {
            defaults.set(newValue, forKey: Key.taskbarOrder)
            NotificationCenter.default.post(name: .taskbarOrderChanged, object: nil)
        }
    }

    var didPromptDock: Bool {
        get { defaults.bool(forKey: Key.didPromptDock) }
        set { defaults.set(newValue, forKey: Key.didPromptDock) }
    }

    /// Skip the one-time Accessibility alert after the user chooses Later.
    var didDismissAccessibilityPrompt: Bool {
        get { defaults.bool(forKey: Key.didDismissAccessibilityPrompt) }
        set { defaults.set(newValue, forKey: Key.didDismissAccessibilityPrompt) }
    }

    /// One-shot: enable Launch at Login the first time this build runs.
    var didConfigureLaunchAtLogin: Bool {
        get { defaults.bool(forKey: Key.didConfigureLaunchAtLogin) }
        set { defaults.set(newValue, forKey: Key.didConfigureLaunchAtLogin) }
    }

    /// Shortcut that opens / closes the Start menu (default: ⌘ / Windows key alone).
    var startMenuHotkey: StartMenuHotkey {
        get {
            guard defaults.object(forKey: Key.startHotkeyKeyCode) != nil else {
                return .default
            }
            return StartMenuHotkey(
                keyCode: UInt16(defaults.integer(forKey: Key.startHotkeyKeyCode)),
                modifierFlags: UInt(defaults.integer(forKey: Key.startHotkeyModifiers)),
                modifierOnly: defaults.bool(forKey: Key.startHotkeyModifierOnly)
            )
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: Key.startHotkeyKeyCode)
            defaults.set(Int(newValue.modifierFlags), forKey: Key.startHotkeyModifiers)
            defaults.set(newValue.modifierOnly, forKey: Key.startHotkeyModifierOnly)
            NotificationCenter.default.post(name: .startMenuHotkeyChanged, object: nil)
        }
    }

    func isPinned(_ bundleID: String) -> Bool {
        pinnedBundleIDs.contains(bundleID)
    }

    func togglePin(_ bundleID: String) {
        var ids = pinnedBundleIDs
        if let idx = ids.firstIndex(of: bundleID) {
            ids.remove(at: idx)
        } else {
            ids.append(bundleID)
        }
        pinnedBundleIDs = ids
    }

    func isHidden(_ bundleID: String) -> Bool {
        hiddenBundleIDs.contains(bundleID)
    }

    func toggleHidden(_ bundleID: String) {
        var ids = hiddenBundleIDs
        if let idx = ids.firstIndex(of: bundleID) {
            ids.remove(at: idx)
        } else {
            ids.append(bundleID)
        }
        hiddenBundleIDs = ids
    }

    func removeHidden(_ bundleID: String) {
        var ids = hiddenBundleIDs
        guard let idx = ids.firstIndex(of: bundleID) else { return }
        ids.remove(at: idx)
        hiddenBundleIDs = ids
    }
}

extension Notification.Name {
    static let taskbarSettingsChanged = Notification.Name("taskbarSettingsChanged")
    static let pinnedAppsChanged = Notification.Name("pinnedAppsChanged")
    static let hiddenAppsChanged = Notification.Name("hiddenAppsChanged")
    static let taskbarOrderChanged = Notification.Name("taskbarOrderChanged")
    static let windowsUpdated = Notification.Name("windowsUpdated")
    static let startMenuHotkeyChanged = Notification.Name("startMenuHotkeyChanged")
}
