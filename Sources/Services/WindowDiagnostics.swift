import Cocoa
import ApplicationServices

/// A window that enumeration considered and rejected, recorded so the reason is
/// visible in the log instead of vanishing into a bare `continue`.
struct WindowDrop {
    let pid: pid_t
    let appName: String
    let axIndex: Int
    let title: String
    let frame: CGRect?
    let reason: String

    /// Stable identity for change detection — excludes the frame, which jitters
    /// while a window is being dragged or resized and would otherwise re-log
    /// the same drop on every refresh.
    var signature: String {
        "\(pid)/\(axIndex)/\(reason)/\(title)"
    }

    var logFields: [String: Any] {
        var fields: [String: Any] = [
            "app": appName,
            "pid": Int(pid),
            "axIndex": axIndex,
            "reason": reason,
            "title": title.isEmpty ? "(untitled)" : title
        ]
        if let frame {
            fields["frame"] = "\(Int(frame.width))x\(Int(frame.height))@\(Int(frame.origin.x)),\(Int(frame.origin.y))"
        }
        return fields
    }
}

/// Window-layer observability: change-only drop logging on the hot path, plus an
/// on-demand full snapshot of every AX window and CG window the app can see.
///
/// The split matters. `refresh()` runs on a poll timer *and* on every AX window
/// event, so logging each considered window every pass would bury the log in
/// duplicates within minutes. Steady state therefore logs only transitions, and
/// the exhaustive detail is available on request via `SIGUSR1`.
enum WindowDiagnostics {

    // MARK: - Change-only drop logging

    private static let lock = NSLock()
    private static var lastDropSignatures: Set<String> = []

    /// Log drops that are new since the previous refresh, and note when a
    /// previously-dropped window stops being dropped.
    static func noteDrops(_ drops: [WindowDrop]) {
        let signatures = Set(drops.map { $0.signature })

        lock.lock()
        let previous = lastDropSignatures
        lastDropSignatures = signatures
        lock.unlock()

        guard signatures != previous else { return }

        for drop in drops where !previous.contains(drop.signature) {
            AppLog.info("window dropped", drop.logFields)
        }
        for gone in previous.subtracting(signatures) {
            AppLog.debug("window no longer dropped", ["signature": gone])
        }
    }

    /// Log the enumerated window set whenever it changes. Called from `refresh()`
    /// only on an actual change, so this is one line per real transition.
    static func noteWindowSet(_ windows: [WindowInfo]) {
        let summary = windows
            .map { info -> String in
                var flags = ""
                if info.isMinimized { flags += "m" }
                if info.isActive { flags += "a" }
                if !info.isOnScreen { flags += "o" }
                let cg = info.cgWindowID.map(String.init) ?? "none"
                return "\(info.appName)[cg=\(cg)\(flags.isEmpty ? "" : ",\(flags)")]"
            }
            .joined(separator: " ")
        AppLog.info("window set changed", ["count": windows.count, "windows": summary])
    }

    // MARK: - Click / raise tracing

    static func noteClick(_ info: WindowInfo) {
        AppLog.info("taskbar click", [
            "app": info.appName,
            "pid": Int(info.pid),
            "cgWindowID": info.cgWindowID.map(String.init) ?? "none",
            "title": info.title.isEmpty ? "(untitled)" : info.title,
            "minimized": info.isMinimized,
            "onScreen": info.isOnScreen
        ])
    }

    static func noteRaiseResult(
        _ info: WindowInfo,
        axResolved: Bool,
        axRestored: Bool,
        realWindows: Int,
        path: String
    ) {
        let level: AppLog.Level = (axRestored || realWindows > 0) ? .info : .warn
        AppLog.write(level, "raise result", [
            "app": info.appName,
            "pid": Int(info.pid),
            "axResolved": axResolved,
            "axRestored": axRestored,
            "realWindows": realWindows,
            "path": path
        ])
    }

    // MARK: - On-demand full snapshot

    /// Install the `SIGUSR1` handler that dumps a full window snapshot to the log.
    ///
    /// `DispatchSource` is used rather than `signal()` because the handler needs to
    /// call Accessibility APIs and allocate, neither of which is legal inside a real
    /// signal trampoline. The signal must be ignored via `signal()` first, otherwise
    /// the default action terminates the process before the source ever fires.
    static func installSnapshotSignalHandler() {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler {
            dumpSnapshot(trigger: "SIGUSR1")
        }
        source.resume()
        snapshotSignalSource = source
        AppLog.info("WindowDiagnostics.snapshotHandlerInstalled", [
            "usage": "kill -USR1 \(ProcessInfo.processInfo.processIdentifier)"
        ])
    }

    private static var snapshotSignalSource: DispatchSourceSignal?

    /// Write every AX window and every layer-0 CG window to the log, with the
    /// attributes enumeration filters actually key off. This is the ground truth
    /// for "why is there a button for an app with no windows".
    static func dumpSnapshot(trigger: String) {
        let trusted = AXIsProcessTrusted()
        AppLog.info("=== window snapshot begin ===", [
            "trigger": trigger,
            "axTrusted": trusted
        ])

        let selfPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != selfPID }

        for app in apps {
            let pid = app.processIdentifier
            let name = app.localizedName ?? app.bundleIdentifier ?? "App"

            // Unfiltered AX window list — deliberately not AccessibilityService.windows(for:),
            // so windows that isStandardWindow rejects still show up here with their subrole.
            let axApp = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
            let axWindows = (value as? [AXUIElement]) ?? []

            AppLog.info("snapshot app", [
                "app": name,
                "pid": Int(pid),
                "bundleID": app.bundleIdentifier ?? "none",
                "axError": err.rawValue,
                "axWindowCount": axWindows.count
            ])

            for (index, ax) in axWindows.enumerated() {
                let subrole = AccessibilityService.stringValue(ax, kAXSubroleAttribute as CFString) ?? "(none)"
                let role = AccessibilityService.stringValue(ax, kAXRoleAttribute as CFString) ?? "(none)"
                let title = AccessibilityService.title(of: ax)
                let minimized = AccessibilityService.isMinimized(ax)
                let frame = AccessibilityService.frame(of: ax)
                AppLog.info("snapshot axWindow", [
                    "app": name,
                    "pid": Int(pid),
                    "axIndex": index,
                    "role": role,
                    "subrole": subrole,
                    "title": title.isEmpty ? "(untitled)" : title,
                    "minimized": minimized,
                    "frame": frame.map { "\(Int($0.width))x\(Int($0.height))@\(Int($0.origin.x)),\(Int($0.origin.y))" } ?? "(none)",
                    "passesStandardWindow": AccessibilityService.isStandardWindow(ax)
                ])
            }
        }

        dumpCGWindows()
        AppLog.info("=== window snapshot end ===", ["trigger": trigger])
    }

    /// Every layer-0 CG window, including ones `buildCGIndex` filters out, with the
    /// filter verdict spelled out. `indexed=false` on an app's only windows is the
    /// ghost-window signature.
    private static func dumpCGWindows() {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            AppLog.warn("snapshot cgWindows unavailable")
            return
        }

        for dict in list {
            let layer = dict[kCGWindowLayer as String] as? Int ?? -1
            guard layer == 0 else { continue }
            let alpha = dict[kCGWindowAlpha as String] as? Double ?? 1
            let owner = dict[kCGWindowOwnerName as String] as? String ?? "?"
            let pid = dict[kCGWindowOwnerPID as String] as? pid_t ?? -1
            let number = dict[kCGWindowNumber as String] as? CGWindowID
            let title = dict[kCGWindowName as String] as? String ?? ""
            let b = dict[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let width = b["Width"] ?? 0
            let height = b["Height"] ?? 0

            // Mirror buildCGIndex's admission rules so the log states the verdict
            // rather than leaving it to be re-derived by hand.
            var rejection: String?
            if alpha <= 0.05 { rejection = "alpha<=0.05" }
            else if number == nil { rejection = "noWindowNumber" }
            else if width < 80 || height < 80 { rejection = "smallerThan80x80" }

            AppLog.info("snapshot cgWindow", [
                "owner": owner,
                "pid": Int(pid),
                "windowID": number.map(String.init) ?? "none",
                "title": title.isEmpty ? "(untitled)" : title,
                "size": "\(Int(width))x\(Int(height))",
                "origin": "\(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0))",
                "alpha": alpha,
                "onScreen": dict[kCGWindowIsOnscreen as String] as? Bool ?? false,
                "indexed": rejection == nil,
                "rejectedBy": rejection ?? "(none)"
            ])
        }
    }
}
