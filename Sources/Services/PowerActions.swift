import AppKit

enum PowerAction: CaseIterable {
    case lock
    case sleep
    case shutDown

    var title: String {
        switch self {
        case .lock: return "Lock Screen"
        case .sleep: return "Sleep"
        case .shutDown: return "Shut Down"
        }
    }

    var symbolName: String {
        switch self {
        case .lock: return "lock.fill"
        case .sleep: return "moon.fill"
        case .shutDown: return "power"
        }
    }

    /// Shut down is irreversible for open work — ask first.
    var needsConfirmation: Bool { self == .shutDown }
}

enum PowerActionRunner {
    static func perform(_ action: PowerAction) {
        AppLog.info("power action", ["action": "\(action)"])
        switch action {
        case .lock:
            lockScreen()
        case .sleep:
            runAppleScript("tell application \"System Events\" to sleep")
        case .shutDown:
            runAppleScript("tell application \"System Events\" to shut down")
        }
    }

    /// Returns true when the user approved (or no confirmation was needed).
    static func confirm(_ action: PowerAction) -> Bool {
        guard action.needsConfirmation else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Shut down this Mac?"
        alert.informativeText = "Apps will be asked to close and any unsaved work may be lost."
        alert.addButton(withTitle: "Shut Down")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func lockScreen() {
        let cgSession = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
        if FileManager.default.isExecutableFile(atPath: cgSession) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cgSession)
            process.arguments = ["-suspend"]
            do {
                try process.run()
                return
            } catch {
                AppLog.info("CGSession lock failed", ["error": "\(error)"])
            }
        }
        // Fallback: the standard Lock Screen keyboard shortcut (Ctrl+Cmd+Q).
        runAppleScript("""
        tell application "System Events" to keystroke "q" using {control down, command down}
        """)
    }

    private static func runAppleScript(_ source: String) {
        guard let script = NSAppleScript(source: source) else { return }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            AppLog.info("power AppleScript failed", ["error": "\(error)"])
        }
    }
}
