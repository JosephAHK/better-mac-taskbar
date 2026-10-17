import AppKit
import ApplicationServices

/// The badges apps put on their Dock icons (unread counts and the like), so task
/// buttons can show them too.
///
/// Apps set badges through NSDockTile, which only the Dock draws; its accessibility
/// tree is the one public place to read them back. Each AXApplicationDockItem under
/// the Dock's list carries the badge as AXStatusLabel. Hiding the Dock doesn't
/// remove them: DockManager only shrinks the tiles to 1pt and auto-hides the Dock,
/// so every running app still has its item.
@MainActor
final class DockBadgeMonitor {
    static let shared = DockBadgeMonitor()

    /// Posted on the main thread when any badge appears, changes or clears.
    static let didChange = Notification.Name("DockBadgeMonitorDidChange")

    private struct Badges: Equatable, Sendable {
        var byBundleID: [String: String] = [:]
        /// Items whose app URL couldn't be resolved fall back to the Dock's title.
        var byAppName: [String: String] = [:]
    }

    private var badges = Badges()
    private var timer: Timer?
    private var pollInFlight = false

    /// Badges are a glanceable count, not a live feed; reading the Dock's tree costs
    /// one AX round-trip per item.
    private let pollInterval: TimeInterval = 2
    private let queue = DispatchQueue(label: "BetterMacTaskbar.dockBadges", qos: .utility)

    private init() {}

    func start() {
        guard timer == nil else { return }
        // Scheduled on the main run loop, so the block runs on main.
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        update(Badges())
    }

    /// The badge for an app, or nil when it has none. The name is only consulted
    /// for Dock items without an app URL, so it isn't worked out otherwise.
    func badge(bundleID: String?, appName: @autoclosure () -> String) -> String? {
        if let bundleID, let label = badges.byBundleID[bundleID] { return label }
        guard !badges.byAppName.isEmpty else { return nil }
        return badges.byAppName[appName()]
    }

    private func poll() {
        // Nobody can see a badge on a bar that is auto-hidden away.
        guard !pollInFlight,
              TaskbarPanelController.shared.isBarVisible,
              AccessibilityService.isTrusted(prompt: false),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return
        }
        pollInFlight = true
        let pid = dock.processIdentifier
        queue.async { [weak self] in
            let read = Self.readBadges(dockPID: pid)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pollInFlight = false
                // A Dock that didn't answer (or is restarting after `killall Dock`)
                // keeps the last badges rather than blinking them all off.
                if let read {
                    self.update(read)
                }
            }
        }
    }

    private func update(_ next: Badges) {
        guard next != badges else { return }
        badges = next
        AppLog.debug("dock badges changed", [
            "apps": next.byBundleID.count + next.byAppName.count
        ])
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Nil when the Dock didn't answer within the messaging timeout.
    nonisolated private static func readBadges(dockPID: pid_t) -> Badges? {
        let dock = AccessibilityService.applicationElement(for: dockPID)
        guard let lists = children(of: dock) else { return nil }
        var result = Badges()
        for list in lists {
            for item in children(of: list) ?? [] {
                guard AccessibilityService.stringValue(item, kAXSubroleAttribute as CFString) == "AXApplicationDockItem",
                      let label = AccessibilityService.stringValue(item, "AXStatusLabel" as CFString),
                      !label.isEmpty else { continue }
                if let bundleID = appURL(of: item).flatMap({ Bundle(url: $0)?.bundleIdentifier }) {
                    result.byBundleID[bundleID] = label
                } else if let title = AccessibilityService.stringValue(item, kAXTitleAttribute as CFString) {
                    result.byAppName[title] = label
                }
            }
        }
        return result
    }

    nonisolated private static func children(of element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
            return nil
        }
        return AccessibilityService.axElements(value)
    }

    nonisolated private static func appURL(of item: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFURLGetTypeID() else { return nil }
        return (value as! CFURL) as URL
    }
}
