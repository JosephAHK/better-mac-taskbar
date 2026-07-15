import Foundation
import AppKit
import ApplicationServices

struct WindowInfo: Identifiable, Equatable {
    let id: String
    let pid: pid_t
    let cgWindowID: CGWindowID?
    let title: String
    let bundleID: String?
    let appName: String
    let isMinimized: Bool
    let isOnScreen: Bool
    let isActive: Bool
    let axElement: AXUIElement?

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.isMinimized == rhs.isMinimized
            && lhs.isOnScreen == rhs.isOnScreen
            && lhs.isActive == rhs.isActive
            && lhs.bundleID == rhs.bundleID
    }

    var displayTitle: String {
        if title.isEmpty { return appName }
        return "\(title) — \(appName)"
    }
}
