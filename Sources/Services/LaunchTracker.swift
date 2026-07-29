import AppKit

/// Tracks apps that were asked to launch but haven't shown a window yet, so the
/// taskbar can show an "opening" indicator during the dead time between click and
/// first window. Windows shows a spinner on the icon here; without it a cold app
/// launch looks like the click did nothing.
final class LaunchTracker {
    static let shared = LaunchTracker()

    /// Give up after this long — some apps open no window at all (agents, login
    /// items, apps that restore to a background space), and a stuck spinner is
    /// worse than none.
    private let timeout: TimeInterval = 25

    private var launching: [String: DispatchWorkItem] = [:]
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier else { return }
                if name == NSWorkspace.didTerminateApplicationNotification {
                    self?.finish(bundleID: bundleID)
                } else {
                    // Activated with a window on screen means the launch landed.
                    self?.finishIfWindowVisible(bundleID: bundleID)
                }
            }
            observers.append(token)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowsUpdated),
            name: .windowsUpdated,
            object: nil
        )
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for token in observers { center.removeObserver(token) }
        NotificationCenter.default.removeObserver(self)
    }

    var launchingBundleIDs: Set<String> { Set(launching.keys) }

    func isLaunching(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return launching[bundleID] != nil
    }

    /// Call right before asking the workspace to open `bundleID`.
    func begin(bundleID: String) {
        launching[bundleID]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.finish(bundleID: bundleID)
        }
        launching[bundleID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        AppLog.info("LaunchTracker.begin \(bundleID)")
        notifyChanged()
    }

    func finish(bundleID: String) {
        guard let work = launching.removeValue(forKey: bundleID) else { return }
        work.cancel()
        AppLog.info("LaunchTracker.finish \(bundleID)")
        notifyChanged()
    }

    @objc private func windowsUpdated() {
        guard !launching.isEmpty else { return }
        for bundleID in launching.keys {
            finishIfWindowVisible(bundleID: bundleID)
        }
    }

    private func finishIfWindowVisible(bundleID: String) {
        guard launching[bundleID] != nil else { return }
        if WindowManager.shared.windows.contains(where: { $0.bundleID == bundleID }) {
            finish(bundleID: bundleID)
        }
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .launchingAppsChanged, object: nil)
    }
}
