import AppKit

/// Keyboard focus for the taskbar's flyouts (Start, Downloads, Trash, Calendar).
///
/// A flyout has to activate this accessory app to take typing, which leaves the app
/// the user was in deactivated. Windows hands focus back when a flyout closes; this
/// does the same, and closes the flyout when the user switches apps instead.
///
/// One instance per flyout controller:
/// - `begin()` right before showing the panel — remembers who had focus, activates us.
/// - `end(restoringFocus:)` when hiding. Pass `false` when the hide was caused by
///   something that moves focus itself (launching or opening something, a click in
///   another app, showing one of our own windows); pass `true` for plain dismissals
///   (Escape, toggling the button, clicking empty taskbar).
@MainActor
final class FlyoutFocus {
    /// The flyout currently holding focus. Opening one flyout from another hides the
    /// first while we're still frontmost, so the newcomer inherits its remembered app.
    private static weak var holder: FlyoutFocus?
    /// Set between a restoring `end` and the deferred re-activation, so a flyout that
    /// opens in that gap takes over the remembered app instead of losing it.
    private static var pendingRestore: NSRunningApplication?

    private let onResignActive: () -> Void
    private var previousApp: NSRunningApplication?
    private var resignObserver: NSObjectProtocol?

    /// `onResignActive` should hide the flyout (with `end(restoringFocus: false)`).
    init(onResignActive: @escaping () -> Void) {
        self.onResignActive = onResignActive
    }

    func begin() {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        } else {
            previousApp = Self.holder?.previousApp ?? Self.pendingRestore
        }
        Self.pendingRestore = nil
        Self.holder = self

        // Accessory (LSUIElement) apps must activate before a panel can take keyboard focus.
        NSApp.activate(ignoringOtherApps: true)

        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onResignActive() }
            }
        }
    }

    func end(restoringFocus: Bool) {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        let app = previousApp
        previousApp = nil
        guard Self.holder === self else { return }
        Self.holder = nil
        guard restoringFocus, NSApp.isActive, let app, !app.isTerminated else { return }

        // Deferred one turn so a flyout opened as part of the same click (switching
        // from Downloads to Trash) can claim focus first and cancel the hand-back.
        Self.pendingRestore = app
        DispatchQueue.main.async {
            guard Self.pendingRestore === app else { return }
            Self.pendingRestore = nil
            guard Self.holder == nil, NSApp.isActive else { return }
            if #available(macOS 14.0, *) {
                NSApp.yieldActivation(to: app)
                app.activate()
            } else {
                app.activate(options: [])
            }
        }
    }
}
