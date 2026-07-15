import Foundation
import AppKit

enum DockManager {
    private static let domain = "com.apple.dock"
    private static let savedTileSizeKey = "BetterMacTaskbar.savedDockTileSize"
    private static let savedAutohideDelayKey = "BetterMacTaskbar.savedDockAutohideDelay"
    private static let savedAutohideTimeKey = "BetterMacTaskbar.savedDockAutohideTime"

    /// Hide the Dock so it never peeks while the taskbar owns the bottom edge.
    static func enableReplaceMode() {
        AppLog.info("DockManager.enableReplaceMode")
        saveOriginalSettingsIfNeeded()

        runDefaults(["write", domain, "autohide", "-bool", "true"])
        // Huge delay = mouse never summons the Dock.
        runDefaults(["write", domain, "autohide-delay", "-float", "1000"])
        // Instant hide if it ever appears.
        runDefaults(["write", domain, "autohide-time-modifier", "-float", "0"])
        runDefaults(["write", domain, "tilesize", "-int", "1"])
        restartDock()
    }

    static func restoreDock() {
        AppLog.info("DockManager.restoreDock")
        let defaults = UserDefaults.standard

        runDefaults(["write", domain, "autohide", "-bool", "false"])

        if defaults.object(forKey: savedAutohideDelayKey) != nil {
            let delay = defaults.float(forKey: savedAutohideDelayKey)
            runDefaults(["write", domain, "autohide-delay", "-float", "\(delay)"])
            defaults.removeObject(forKey: savedAutohideDelayKey)
        } else {
            runDefaults(["delete", domain, "autohide-delay"])
        }

        if defaults.object(forKey: savedAutohideTimeKey) != nil {
            let time = defaults.float(forKey: savedAutohideTimeKey)
            runDefaults(["write", domain, "autohide-time-modifier", "-float", "\(time)"])
            defaults.removeObject(forKey: savedAutohideTimeKey)
        } else {
            runDefaults(["delete", domain, "autohide-time-modifier"])
        }

        let tileSize = defaults.object(forKey: savedTileSizeKey) as? Int ?? 48
        runDefaults(["write", domain, "tilesize", "-int", "\(tileSize)"])
        defaults.removeObject(forKey: savedTileSizeKey)

        restartDock()
    }

    private static func saveOriginalSettingsIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: savedTileSizeKey) == nil else { return }

        let tileSize = readInt("tilesize") ?? 48
        defaults.set(tileSize, forKey: savedTileSizeKey)

        if let delay = readFloat("autohide-delay") {
            defaults.set(delay, forKey: savedAutohideDelayKey)
        }
        if let time = readFloat("autohide-time-modifier") {
            defaults.set(time, forKey: savedAutohideTimeKey)
        }
    }

    private static func readInt(_ key: String) -> Int? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", domain, key]
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Int(str) else { return nil }
        return value
    }

    private static func readFloat(_ key: String) -> Float? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", domain, key]
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Float(str) else { return nil }
        return value
    }

    private static func runDefaults(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = args
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    private static func restartDock() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try? process.run()
        process.waitUntilExit()
    }
}

enum PinManager {
    static var pinnedBundleIDs: [String] {
        get { TaskbarSettings.shared.pinnedBundleIDs }
        set { TaskbarSettings.shared.pinnedBundleIDs = newValue }
    }

    static func isPinned(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return TaskbarSettings.shared.isPinned(bundleID)
    }

    static func togglePin(bundleID: String?) {
        guard let bundleID else { return }
        TaskbarSettings.shared.togglePin(bundleID)
    }

    static func launch(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    static func icon(forBundleID bundleID: String) -> NSImage? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    static func appName(forBundleID bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }
}

enum HideManager {
    static func isHidden(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return TaskbarSettings.shared.isHidden(bundleID)
    }

    static func toggleHidden(bundleID: String?) {
        guard let bundleID else { return }
        TaskbarSettings.shared.toggleHidden(bundleID)
    }

    static func removeHidden(bundleID: String) {
        TaskbarSettings.shared.removeHidden(bundleID)
    }
}
