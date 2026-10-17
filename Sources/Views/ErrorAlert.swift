import AppKit

/// Modal warnings for actions that failed, so a failure is never silent.
@MainActor
enum ErrorAlert {
    /// AppleScript's errAEEventNotPermitted — the user hasn't allowed (or has
    /// revoked) this app's Automation access to the target app.
    static let automationDeniedCode = -1743

    static func show(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        // The flyout or menu that triggered this may have handed focus back already.
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// For a failed Apple event to `targetApp`; explains the Automation permission
    /// when that's the cause, since the raw -1743 message doesn't say where to fix it.
    static func showAppleScriptFailure(title: String, targetApp: String, code: Int?, message: String) {
        guard code == automationDeniedCode else {
            show(title: title, message: message)
            return
        }
        show(
            title: title,
            message: "Better Mac Taskbar isn’t allowed to control \(targetApp). Turn it on in System Settings → Privacy & Security → Automation → Better Mac Taskbar → \(targetApp)."
        )
    }
}
