import Foundation
import AppKit

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
}
