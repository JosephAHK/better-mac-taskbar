import AppKit
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
    static let minimumLevel: Level = {
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
    private static let maxFileBytes: Int64 = 8 * 1024 * 1024
    private static let heartbeatInterval: TimeInterval = 300
    // These three are only touched on `queue`, which is what makes the unsafe access sound.
    nonisolated(unsafe) private static var heartbeatTimer: DispatchSourceTimer?
    nonisolated(unsafe) private static var started = false
    /// Retained for the life of the process; a released signal source stops firing.
    nonisolated(unsafe) private static var terminationSignalSources: [DispatchSourceSignal] = []
    /// ISO8601DateFormatter is documented thread-safe (it just isn't marked
    /// Sendable); building one per line was the cost.
    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func bootstrap() {
        queue.sync {
            guard !started else { return }
            started = true
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            openLogFD()
            rotateIfNeededUnlocked()
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
        queue.sync { startHeartbeat() }
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
        queue.sync { stopHeartbeat() }
        info("shutdown", ["reason": reason])
        queue.sync {}
    }

    // MARK: - Internals

    static func write(_ level: Level, _ message: String, _ fields: [String: Any] = [:]) {
        guard level >= minimumLevel else { return }
        // Stamp on the caller's thread so the time is when it happened, not when
        // the queue got to it.
        let date = Date()
        let pid = ProcessInfo.processInfo.processIdentifier
        var body = "[\(level.rawValue)] pid=\(pid) \(message)"
        if !fields.isEmpty {
            let pairs = fields.keys.sorted().map { key in
                "\(key)=\(stringify(fields[key]!))"
            }
            body += " " + pairs.joined(separator: " ")
        }

        NSLog("[BetterMacTaskbar] %@", body)

        queue.async { [body] in
            rotateIfNeededUnlocked()
            appendUnlocked("\(timestampFormatter.string(from: date)) \(body)\n")
        }
    }

    /// One O_APPEND descriptor shared with the signal handler. O_APPEND makes each
    /// write(2) land at the current end even when the handler writes concurrently.
    private static func appendUnlocked(_ line: String) {
        guard _appLogFD >= 0 else { return }
        var line = line
        line.withUTF8 { bytes in
            _ = Darwin.write(_appLogFD, bytes.baseAddress, bytes.count)
        }
    }

    /// One stat per line: reopens if the log was deleted out from under us (the fd
    /// would otherwise keep writing to the unlinked file) and rotates at 8MB.
    private static func rotateIfNeededUnlocked() {
        var attributes = stat()
        guard stat(fileURL.path, &attributes) == 0 else {
            openLogFD()
            return
        }
        guard attributes.st_size >= maxFileBytes else { return }
        let backup = directoryURL.appendingPathComponent("app.1.log")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: fileURL, to: backup)
        openLogFD()
    }

    /// Opens the new descriptor before retiring the old one so the signal handler
    /// never observes a closed (or reused) fd number.
    private static func openLogFD() {
        let fd = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        let old = _appLogFD
        _appLogFD = fd
        if old >= 0 {
            close(old)
        }
    }

    private static func startHeartbeat() {
        stopHeartbeat()
        // 5 minutes, not 60s. The heartbeat only needs to prove liveness and
        // bracket the time of an unlogged death; at 60s it was ~99% of the log
        // and pushed real events out of the rotation window.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        timer.setEventHandler {
            // INFO, not DEBUG: the heartbeat is what brackets the time of a death that
            // never got to log anything, so it has to survive at the default level.
            info("heartbeat", ["uptimeSec": Int(ProcessInfo.processInfo.systemUptime)])
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private static func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
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
            // Written directly, not via `queue`: the process is about to die and an
            // async append would never run. Qualified with `AppLog.` because a C
            // function pointer can't capture the implicit `self` metatype.
            AppLog.appendUnlocked("\(AppLog.timestampFormatter.string(from: Date())) [ERROR] uncaughtException name=\(name) reason=\"\(reason)\" stack=\"\(stack)\"\n")
            NSLog("[BetterMacTaskbar] uncaughtException: %@ — %@", name, reason)
        }
    }

    private static func installSignalHandlers() {
        // SIGKILL cannot be caught. SIGABRT means the process is already dying, so
        // it only gets the async-signal-safe raw handler.
        signal(SIGABRT, appLogSignalHandler)

        // SIGTERM is what `pkill` (build.sh, the restart workflow) sends. Dying on
        // the spot would skip applicationWillTerminate and leave the Dock hidden,
        // so route it through a normal quit on the main queue instead.
        for (number, name) in [(SIGTERM, "SIGTERM"), (SIGINT, "SIGINT")] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    info("caughtSignal", ["signal": name])
                    NSApp.terminate(nil)
                }
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }
}

/// Kept outside the enum so the C signal trampoline can write without Swift captures.
/// Written only on `AppLog.queue`; the handler's unsynchronized read is an aligned
/// Int32 load, and `openLogFD` swaps before closing so it is never a stale fd.
nonisolated(unsafe) private var _appLogFD: Int32 = -1

private func appLogSignalHandler(_ received: Int32) {
    let msg: StaticString = "caughtSignal signal=SIGABRT\n"
    if _appLogFD >= 0 {
        _ = write(_appLogFD, msg.utf8Start, msg.utf8CodeUnitCount)
    }
    signal(received, SIG_DFL)
    raise(received)
}
