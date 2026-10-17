import Foundation
import AppKit

/// Hides the Dock while the taskbar owns the bottom edge, and puts it back.
///
/// All `defaults` / `killall` work runs on one serial queue: it shells out and
/// blocks, so it must stay off the main thread, and apply/restore must run in
/// the order they were requested or a quick toggle could leave the Dock hidden.
enum DockManager {
    private static let domain = "com.apple.dock"
    private static let savedTileSizeKey = "BetterMacTaskbar.savedDockTileSize"
    private static let savedAutohideKey = "BetterMacTaskbar.savedDockAutohide"
    private static let savedAutohideDelayKey = "BetterMacTaskbar.savedDockAutohideDelay"
    private static let savedAutohideTimeKey = "BetterMacTaskbar.savedDockAutohideTime"

    private static let queue = DispatchQueue(label: "com.bettermac.taskbar.dock")

    /// The Dock preferences this manager touches. `nil` means the key is absent,
    /// i.e. the Dock uses its built-in default.
    private struct DockState: Equatable {
        var autohide: Bool?
        var autohideDelay: Double?
        var autohideTime: Double?
        var tileSize: Int?

        /// Huge delay = the mouse never summons the Dock; zero time = instant hide
        /// if it ever appears; 1pt tiles leave nothing to see while it animates.
        static let hidden = DockState(autohide: true, autohideDelay: 1000, autohideTime: 0, tileSize: 1)
    }

    /// Originals are saved on the first hide and cleared only by a completed
    /// restore, so their presence means the Dock may still be hidden by us —
    /// including after a crash or force-quit that skipped the terminate path.
    static var hasSavedOriginals: Bool {
        UserDefaults.standard.object(forKey: savedTileSizeKey) != nil
    }

    static func enableReplaceMode() {
        queue.async {
            AppLog.info("DockManager.enableReplaceMode")
            saveOriginalSettingsIfNeeded()
            apply(.hidden)
        }
    }

    /// No-op unless originals were saved. Pass `waitUntilDone` at termination so
    /// the Dock is back before the process exits.
    static func restoreDock(waitUntilDone: Bool = false) {
        let work: @Sendable () -> Void = {
            guard hasSavedOriginals else { return }
            AppLog.info("DockManager.restoreDock")
            let defaults = UserDefaults.standard
            apply(DockState(
                autohide: defaults.object(forKey: savedAutohideKey) as? Bool,
                autohideDelay: defaults.object(forKey: savedAutohideDelayKey) as? Double,
                autohideTime: defaults.object(forKey: savedAutohideTimeKey) as? Double,
                tileSize: defaults.object(forKey: savedTileSizeKey) as? Int
            ))
            for key in [savedTileSizeKey, savedAutohideKey, savedAutohideDelayKey, savedAutohideTimeKey] {
                defaults.removeObject(forKey: key)
            }
        }
        if waitUntilDone {
            queue.sync(execute: work)
        } else {
            queue.async(execute: work)
        }
    }

    private static func saveOriginalSettingsIfNeeded() {
        guard !hasSavedOriginals else { return }
        let current = readState()
        let defaults = UserDefaults.standard
        // The tile size doubles as the "originals saved" marker, so it is always
        // stored; 48 is the Dock's own default when the key is absent.
        defaults.set(current.tileSize ?? 48, forKey: savedTileSizeKey)
        if let autohide = current.autohide { defaults.set(autohide, forKey: savedAutohideKey) }
        if let delay = current.autohideDelay { defaults.set(delay, forKey: savedAutohideDelayKey) }
        if let time = current.autohideTime { defaults.set(time, forKey: savedAutohideTimeKey) }
    }

    /// Writes only the keys that differ and restarts the Dock only if something
    /// changed — otherwise every launch would flash the Dock for nothing.
    private static func apply(_ target: DockState) {
        let current = readState()
        guard current != target else { return }

        if current.autohide != target.autohide {
            write("autohide", target.autohide.map { ["-bool", $0 ? "true" : "false"] })
        }
        if current.autohideDelay != target.autohideDelay {
            write("autohide-delay", target.autohideDelay.map { ["-float", "\($0)"] })
        }
        if current.autohideTime != target.autohideTime {
            write("autohide-time-modifier", target.autohideTime.map { ["-float", "\($0)"] })
        }
        if current.tileSize != target.tileSize {
            write("tilesize", target.tileSize.map { ["-int", "\($0)"] })
        }
        run("/usr/bin/killall", ["Dock"])
    }

    /// The suite reflects `defaults write` from another process immediately
    /// (checked against an external write), so reads need no subprocess.
    /// Read as NSNumber so it doesn't matter whether a value was stored as an
    /// integer, float or boolean.
    private static func readState() -> DockState {
        let dock = UserDefaults(suiteName: domain)
        return DockState(
            autohide: (dock?.object(forKey: "autohide") as? NSNumber)?.boolValue,
            autohideDelay: (dock?.object(forKey: "autohide-delay") as? NSNumber)?.doubleValue,
            autohideTime: (dock?.object(forKey: "autohide-time-modifier") as? NSNumber)?.doubleValue,
            tileSize: (dock?.object(forKey: "tilesize") as? NSNumber)?.intValue
        )
    }

    /// `nil` value deletes the key so the Dock falls back to its default.
    private static func write(_ key: String, _ typedValue: [String]?) {
        if let typedValue {
            run("/usr/bin/defaults", ["write", domain, key] + typedValue)
        } else {
            run("/usr/bin/defaults", ["delete", domain, key])
        }
    }

    /// Returns the exit status, or `nil` if the process could not be launched —
    /// `waitUntilExit` on a process that never started raises an ObjC exception.
    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            AppLog.error("DockManager process launch failed", [
                "path": path,
                "error": error.localizedDescription
            ])
            return nil
        }
        process.waitUntilExit()
        return process.terminationStatus
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

    @MainActor
    static func launch(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        // Mark before the call so the taskbar shows the opening indicator on the
        // very next layout pass, not after the workspace gets around to it.
        LaunchTracker.shared.begin(bundleID: bundleID)
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            guard error != nil || app == nil else { return }
            DispatchQueue.main.async { LaunchTracker.shared.finish(bundleID: bundleID) }
        }
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
