import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the app as a Login Item (macOS 13+).
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status == .enabled {
                    AppLog.info("LaunchAtLogin already enabled")
                    return true
                }
                try SMAppService.mainApp.register()
            } else {
                if SMAppService.mainApp.status == .notRegistered {
                    AppLog.info("LaunchAtLogin already unregistered")
                    return true
                }
                try SMAppService.mainApp.unregister()
            }
            AppLog.info("LaunchAtLogin.setEnabled", ["enabled": enabled, "ok": true])
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
