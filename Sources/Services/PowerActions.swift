import AppKit

enum PowerAction: CaseIterable {
    case lock
    case logOut
    case sleep
    case restart
    case shutDown

    var title: String {
        switch self {
        case .lock: return "Lock Screen"
        case .logOut: return "Log Out"
        case .sleep: return "Sleep"
        case .restart: return "Restart"
        case .shutDown: return "Shut Down"
        }
    }

    var symbolName: String {
        switch self {
        case .lock: return "lock.fill"
        case .logOut: return "rectangle.portrait.and.arrow.right"
        case .sleep: return "moon.fill"
        case .restart: return "arrow.clockwise"
        case .shutDown: return "power"
        }
    }

    /// Wording for actions that close every app — irreversible for open work, so ask first.
    fileprivate var confirmation: (question: String, button: String)? {
        switch self {
        case .lock, .sleep: return nil
        case .logOut: return ("Log out of this Mac?", "Log Out")
        case .restart: return ("Restart this Mac?", "Restart")
        case .shutDown: return ("Shut down this Mac?", "Shut Down")
        }
    }
}

@MainActor
enum PowerActionRunner {
    static func perform(_ action: PowerAction) {
        AppLog.info("power action", ["action": "\(action)"])
        switch action {
        case .lock:
            lockScreen()
        case .logOut:
            runSystemEvents("log out", action: action)
        case .sleep:
            runSystemEvents("sleep", action: action)
        case .restart:
            runSystemEvents("restart", action: action)
        case .shutDown:
            runSystemEvents("shut down", action: action)
        }
    }

    /// Returns true when the user approved (or no confirmation was needed).
    static func confirm(_ action: PowerAction) -> Bool {
        guard let confirmation = action.confirmation else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = confirmation.question
        alert.informativeText = "Apps will be asked to close and any unsaved work may be lost."
        alert.addButton(withTitle: confirmation.button)
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
        runSystemEvents("keystroke \"q\" using {control down, command down}", action: .lock)
    }

    private static func runSystemEvents(_ command: String, action: PowerAction) {
        guard let script = NSAppleScript(source: "tell application \"System Events\" to \(command)") else { return }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return }
        AppLog.info("power AppleScript failed", ["error": "\(error)"])
        ErrorAlert.showAppleScriptFailure(
            title: "Couldn’t \(action.title)",
            targetApp: "System Events",
            code: error[NSAppleScript.errorNumber] as? Int,
            message: error[NSAppleScript.errorMessage] as? String ?? "The request to System Events failed."
        )
    }
}
