import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// Registered with the system, whether or not the user has approved it yet.
    /// This is what the Settings toggle reflects: `.requiresApproval` means our
    /// request stands but the user turned it off in Login Items, so the app will
    /// not actually launch until they approve it there.
    static var isRegistered: Bool {
        status == .enabled || status == .requiresApproval
    }

    static var needsApproval: Bool {
        status == .requiresApproval
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Registers or unregisters the app as a Login Item (macOS 13+).
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if isRegistered {
                    AppLog.info("LaunchAtLogin already registered", ["needsApproval": needsApproval])
                    return true
                }
                try SMAppService.mainApp.register()
            } else {
                if status == .notRegistered {
                    AppLog.info("LaunchAtLogin already unregistered")
                    return true
                }
                try SMAppService.mainApp.unregister()
            }
            AppLog.info("LaunchAtLogin.setEnabled", [
                "enabled": enabled,
                "ok": true,
                "needsApproval": needsApproval
            ])
            return true
        } catch {
            AppLog.error("LaunchAtLogin.setEnabled failed", [
                "enabled": enabled,
                "error": error.localizedDescription
            ])
            NSLog("LaunchAtLogin: \(error.localizedDescription)")
            return false
        }
    }
}
