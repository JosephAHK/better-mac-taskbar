import Foundation
import AppKit
import ApplicationServices

/// `@unchecked Sendable` because of `axElement`: an AXUIElement is an immutable CF
/// reference, and AX calls on it are safe from any thread. Window actions hand
/// snapshots to a background queue.
struct WindowInfo: Identifiable, Equatable, @unchecked Sendable {
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

    /// Drives `windows` publication, so it covers everything window actions key off.
    /// cgWindowID matters on its own: the CG fallback's `app-<pid>` id stays put while
    /// the window behind it changes, and an unpublished change left actions targeting
    /// the old window. axElement is left out — every refresh copies fresh refs.
    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id
            && lhs.cgWindowID == rhs.cgWindowID
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

    func with(isActive: Bool) -> WindowInfo {
        WindowInfo(
            id: id,
            pid: pid,
            cgWindowID: cgWindowID,
            title: title,
            bundleID: bundleID,
            appName: appName,
            isMinimized: isMinimized,
            isOnScreen: isOnScreen,
            isActive: isActive,
            axElement: axElement
        )
    }
}
