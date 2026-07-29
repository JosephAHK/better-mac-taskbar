import Foundation
import Darwin

/// File logger for diagnosing crashes / silent exits and day-to-day misbehaviour.
///
/// Primary log: `~/Library/Logs/BetterMacTaskbar/app.log`
/// Rotated backups: `app.1.log`, `app.2.log`
///
/// Levels: `debug` is off by default (the window poll runs ~3×/second, so debug is
/// chatty by design). Turn it on in Settings → "Verbose logging", reproduce the
/// problem, then hand over `~/Library/Logs/BetterMacTaskbar/app.log`.
enum AppLog {
    enum Level: Int, Comparable {
        case debug = 0
        case info = 1
        case warn = 2
        case error = 3

        var name: String {
            switch self {
            case .debug: return "DEBUG"
            case .info: return "INFO"
            case .warn: return "WARN"
            case .error: return "ERROR"
            }
        }

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// UserDefaults key mirrored by the Settings checkbox.
    static let verboseKey = "verboseLogging"

    static let directoryURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("BetterMacTaskbar", isDirectory: true)
    }()

    static let fileURL: URL = directoryURL.appendingPathComponent("app.log", isDirectory: false)

    private static let queue = DispatchQueue(label: "com.bettermac.taskbar.applog")
    private static let maxFileBytes: UInt64 = 4 * 1024 * 1024
    private static let backupCount = 2
    private static var heartbeatTimer: DispatchSourceTimer?
    private static var started = false
    /// Cached so every debug call doesn't hit UserDefaults. Updated via setVerbose.
    private static var minimumLevelStorage = Level.info
    private static let levelLock = NSLock()
    private static var throttleStamps: [String: TimeInterval] = [:]
    private static let throttleLock = NSLock()

    static var isVerbose: Bool { minimumLevel == .debug }

    static var minimumLevel: Level {
        levelLock.lock()
        defer { levelLock.unlock() }
        return minimumLevelStorage
    }

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

        applyVerboseFromDefaults()

        let pid = ProcessInfo.processInfo.processIdentifier
        let path = Bundle.main.bundlePath
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        info("bootstrap", [
            "pid": pid,
            "version": version,
            "bundlePath": path,
            "logFile": fileURL.path,
            "verbose": isVerbose
        ])
        startHeartbeat()
    }

    /// Read the persisted verbose flag (also honours `BMT_VERBOSE_LOG=1` for terminal runs).
    static func applyVerboseFromDefaults() {
        let env = ProcessInfo.processInfo.environment["BMT_VERBOSE_LOG"]
        let envOn = env == "1" || env?.lowercased() == "true"
        setVerbose(envOn || UserDefaults.standard.bool(forKey: verboseKey), persist: false)
    }

    static func setVerbose(_ on: Bool, persist: Bool = true) {
        let target: Level = on ? .debug : .info
        levelLock.lock()
        let changed = minimumLevelStorage != target
        minimumLevelStorage = target
        levelLock.unlock()
        if persist {
            UserDefaults.standard.set(on, forKey: verboseKey)
        }
        if changed {
            info("logLevel changed", ["verbose": on])
        }
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

    /// Log at most once per `seconds` for a given key — for handlers that fire on
    /// every mouse move / poll tick where a full stream would bury everything else.
    static func throttled(
        _ key: String,
        seconds: TimeInterval = 2,
        level: Level = .debug,
        _ message: String,
        _ fields: [String: Any] = [:]
    ) {
        guard level >= minimumLevel else { return }
        let now = ProcessInfo.processInfo.systemUptime
        throttleLock.lock()
        let last = throttleStamps[key]
        let allowed = last == nil || now - last! >= seconds
        if allowed { throttleStamps[key] = now }
        throttleLock.unlock()
        guard allowed else { return }
        write(level, message, fields)
    }

    /// Time a block and log when it takes longer than `warnAfter` — most stalls in this
    /// app come from synchronous AX / AppleScript calls landing on the main thread.
    @discardableResult
    static func measure<T>(
        _ name: String,
        warnAfter: TimeInterval = 0.25,
        _ fields: [String: Any] = [:],
        _ body: () throws -> T
    ) rethrows -> T {
        let start = ProcessInfo.processInfo.systemUptime
        defer {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            var payload = fields
            payload["ms"] = Int(elapsed * 1000)
            payload["thread"] = Thread.isMainThread ? "main" : "bg"
            if elapsed >= warnAfter {
                write(.warn, "slow \(name)", payload)
            } else {
                write(.debug, name, payload)
            }
        }
        return try body()
    }

    /// Flush a final line before intentional quit.
    static func shutdown(_ reason: String) {
        stopHeartbeat()
        info("shutdown", ["reason": reason])
        queue.sync {}
    }

    // MARK: - Diagnostics

    /// Last `lines` log lines, oldest first. Used by the "Copy Diagnostics" menu item.
    static func tail(lines: Int = 200) -> String {
        queue.sync {}
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return "(log unreadable at \(fileURL.path))"
        }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        return all.suffix(lines).joined(separator: "\n")
    }

    /// Human-readable snapshot of app state + recent log lines, for bug reports.
    /// `state` lets callers inject values AppLog can't see (permissions, settings, windows).
    static func diagnosticsReport(state: [String: Any] = [:], logLines: Int = 200) -> String {
        let process = ProcessInfo.processInfo
        var header: [String: Any] = [
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "bundlePath": Bundle.main.bundlePath,
            "pid": process.processIdentifier,
            "os": process.operatingSystemVersionString,
            "uptimeSec": Int(process.systemUptime),
            "verboseLogging": isVerbose,
            "logFile": fileURL.path
        ]
        for (key, value) in state {
            header[key] = value
        }
        let headerText = header.keys.sorted()
            .map { "\($0): \(stringify(header[$0]!))" }
            .joined(separator: "\n")
        return """
        === Better Mac Taskbar diagnostics ===
        \(headerText)

        === last \(logLines) log lines ===
        \(tail(lines: logLines))
        """
    }

    // MARK: - Internals

    private static func write(_ level: Level, _ message: String, _ fields: [String: Any]) {
        guard level >= minimumLevel else { return }

        let ts = isoTimestamp()
        let pid = ProcessInfo.processInfo.processIdentifier
        var line = "\(ts) [\(level.name)] pid=\(pid) \(message)"
        if !fields.isEmpty {
            let pairs = fields.keys.sorted().map { key in
                "\(key)=\(stringify(fields[key]!))"
            }
            line += " " + pairs.joined(separator: " ")
        }
        line += "\n"

        // Console gets the important lines only — the file keeps everything.
        if level >= .warn {
            NSLog("[BetterMacTaskbar] %@", line.trimmingCharacters(in: .newlines))
        }

        queue.async {
            rotateIfNeededUnlocked()
            appendUnlocked(line)
        }
    }

    private static func appendUnlocked(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if _appLogFD < 0 || !FileManager.default.fileExists(atPath: fileURL.path) {
            openLogFD()
        }
        guard _appLogFD >= 0 else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(_appLogFD, base.advanced(by: offset), raw.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    private static func rotateIfNeededUnlocked() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? UInt64,
              size >= maxFileBytes else { return }
        let fm = FileManager.default
        // app.1.log → app.2.log, app.log → app.1.log; oldest falls off the end.
        try? fm.removeItem(at: directoryURL.appendingPathComponent("app.\(backupCount).log"))
        var index = backupCount - 1
        while index >= 1 {
            let from = directoryURL.appendingPathComponent("app.\(index).log")
            let to = directoryURL.appendingPathComponent("app.\(index + 1).log")
            if fm.fileExists(atPath: from.path) {
                try? fm.moveItem(at: from, to: to)
            }
            index -= 1
        }
        try? fm.moveItem(at: fileURL, to: directoryURL.appendingPathComponent("app.1.log"))
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
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler {
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
