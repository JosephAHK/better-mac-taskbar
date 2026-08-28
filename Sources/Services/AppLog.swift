import Foundation
import Darwin

/// File logger for diagnosing crashes / silent exits.
///
/// Primary log: `~/Library/Logs/BetterMacTaskbar/app.log`
/// Rotated backup: `~/Library/Logs/BetterMacTaskbar/app.1.log`
enum AppLog {
    enum Level: String, Comparable {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"

        var severity: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .warn: return 2
            case .error: return 3
            }
        }

        static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.severity < rhs.severity
        }
    }

    /// Lines below this level are discarded. DEBUG is opt-in so verbose window
    /// tracing can be switched on for a diagnosis session without permanently
    /// paying the log volume.
    ///
    /// Enable with either:
    ///   defaults write com.bettermac.taskbar verboseLogging -bool YES   (persists)
    ///   BMT_VERBOSE_LOG=1                                              (one launch)
    static var minimumLevel: Level = {
        if ProcessInfo.processInfo.environment["BMT_VERBOSE_LOG"] == "1" { return .debug }
        if UserDefaults.standard.bool(forKey: "verboseLogging") { return .debug }
        return .info
    }()

    static let directoryURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("BetterMacTaskbar", isDirectory: true)
    }()

    static let fileURL: URL = directoryURL.appendingPathComponent("app.log", isDirectory: false)

    private static let queue = DispatchQueue(label: "com.bettermac.taskbar.applog")
    private static let maxFileBytes: UInt64 = 8 * 1024 * 1024
    private static let heartbeatInterval: TimeInterval = 300
    private static var heartbeatTimer: DispatchSourceTimer?
    private static var started = false

    static func bootstrap() {
        queue.sync {
            guard !started else { return }
            started = true
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            rotateIfNeededUnlocked()
            openLogFD()
            installExceptionHook()
            installSignalHandlers()
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let path = Bundle.main.bundlePath
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        info("bootstrap", [
            "pid": pid,
            "version": version,
            "bundlePath": path,
            "logFile": fileURL.path,
            "logLevel": minimumLevel.rawValue
        ])
        startHeartbeat()
        WindowDiagnostics.installSnapshotSignalHandler()
    }

    static func debug(_ message: String, _ fields: [String: Any] = [:]) {
        write(.debug, message, fields)
    }

    static func info(_ message: String, _ fields: [String: Any] = [:]) {
        write(.info, message, fields)
    }

    static func warn(_ message: String, _ fields: [String: Any] = [:]) {
        write(.warn, message, fields)
    }

    static func error(_ message: String, _ fields: [String: Any] = [:]) {
        write(.error, message, fields)
    }

    /// Flush a final line before intentional quit.
    static func shutdown(_ reason: String) {
        stopHeartbeat()
        info("shutdown", ["reason": reason])
        queue.sync {}
    }

    // MARK: - Internals

    static func write(_ level: Level, _ message: String, _ fields: [String: Any] = [:]) {
        guard level >= minimumLevel else { return }
        let ts = isoTimestamp()
        let pid = ProcessInfo.processInfo.processIdentifier
        var line = "\(ts) [\(level.rawValue)] pid=\(pid) \(message)"
        if !fields.isEmpty {
            let pairs = fields.keys.sorted().map { key in
                "\(key)=\(stringify(fields[key]!))"
            }
            line += " " + pairs.joined(separator: " ")
        }
        line += "\n"

        NSLog("[BetterMacTaskbar] %@", line.trimmingCharacters(in: .newlines))

        queue.async {
            rotateIfNeededUnlocked()
            appendUnlocked(line)
        }
    }

    private static func appendUnlocked(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            openLogFD()
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private static func rotateIfNeededUnlocked() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? UInt64,
              size >= maxFileBytes else { return }
        let backup = directoryURL.appendingPathComponent("app.1.log")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: fileURL, to: backup)
        openLogFD()
    }

    private static func openLogFD() {
        if _appLogFD >= 0 {
            close(_appLogFD)
            _appLogFD = -1
        }
        let path = fileURL.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        _appLogFD = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    }

    private static func startHeartbeat() {
        stopHeartbeat()
        // 5 minutes, not 60s. The heartbeat only needs to prove liveness and
        // bracket the time of an unlogged death; at 60s it was ~99% of the log
        // and pushed real events out of the rotation window.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        timer.setEventHandler {
            // Deliberately not level-gated: the heartbeat is what brackets the time
            // of a death that never got to log anything, so it has to survive at the
            // default level.
            let ts = isoTimestamp()
            let pid = ProcessInfo.processInfo.processIdentifier
            let uptime = Int(ProcessInfo.processInfo.systemUptime)
            appendUnlocked("\(ts) [DEBUG] pid=\(pid) heartbeat uptimeSec=\(uptime)\n")
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private static func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    private static func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func stringify(_ value: Any) -> String {
        if let s = value as? String {
            return s.contains(" ") ? "\"\(s)\"" : s
        }
        if let b = value as? Bool { return b ? "true" : "false" }
        if let n = value as? NSNumber { return n.stringValue }
        return "\"\(String(describing: value))\""
    }

    private static func installExceptionHook() {
        NSSetUncaughtExceptionHandler { exception in
            let reason = exception.reason ?? ""
            let name = exception.name.rawValue
            let stack = exception.callStackSymbols.prefix(12).joined(separator: " | ")
            let line = "\(ISO8601DateFormatter().string(from: Date())) [ERROR] uncaughtException name=\(name) reason=\"\(reason)\" stack=\"\(stack)\"\n"
            if let data = line.data(using: .utf8) {
                try? FileManager.default.createDirectory(at: AppLog.directoryURL, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: AppLog.fileURL.path),
                   let handle = try? FileHandle(forWritingTo: AppLog.fileURL) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                } else {
                    try? data.write(to: AppLog.fileURL, options: .atomic)
                }
            }
            NSLog("[BetterMacTaskbar] uncaughtException: %@ — %@", name, reason)
        }
    }

    private static func installSignalHandlers() {
        // SIGKILL cannot be caught. SIGTERM is what `pkill` sends by default.
        signal(SIGTERM, appLogSignalHandler)
        signal(SIGINT, appLogSignalHandler)
        signal(SIGABRT, appLogSignalHandler)
    }
}

/// Kept outside the enum so the C signal trampoline can write without Swift captures.
private var _appLogFD: Int32 = -1

private func appLogSignalHandler(_ received: Int32) {
    let msg: StaticString
    switch received {
    case SIGTERM: msg = "caughtSignal signal=SIGTERM\n"
    case SIGINT: msg = "caughtSignal signal=SIGINT\n"
    case SIGABRT: msg = "caughtSignal signal=SIGABRT\n"
    default: msg = "caughtSignal signal=OTHER\n"
    }
    if _appLogFD >= 0 {
        _ = write(_appLogFD, msg.utf8Start, msg.utf8CodeUnitCount)
    }
    signal(received, SIG_DFL)
    raise(received)
}
