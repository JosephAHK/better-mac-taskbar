import AppKit

/// System display preferences the taskbar's hand-painted chrome has to follow.
///
/// Most bar state is drawn with raw layer colours, which AppKit cannot re-resolve
/// by itself when the user changes the accent colour. Views register through
/// `addObserver` and repaint from that callback instead.
@MainActor
enum TaskbarAppearance {
    /// Calls `selector` whenever the accent colour changes.
    /// Selector-based observers are dropped automatically when `observer` deallocates.
    static func addObserver(_ observer: Any, selector: Selector) {
        NotificationCenter.default.addObserver(
            observer,
            selector: selector,
            name: NSColor.systemColorsDidChangeNotification,
            object: nil
        )
    }
}

extension NSView {
    /// `NSColor.cgColor` snapshots a dynamic colour against whichever appearance
    /// happens to be current, not this view's — resolve it here so layer colours
    /// match the dark taskbar even when the system is in Light mode.
    func resolvedCGColor(_ color: NSColor) -> CGColor {
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved
    }
}
