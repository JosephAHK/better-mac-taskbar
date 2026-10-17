import AppKit

/// System display preferences the taskbar's hand-painted chrome has to follow.
///
/// Most bar state is drawn with raw layer colours, which AppKit cannot re-resolve
/// by itself when the user changes the accent colour or toggles Reduce
/// Transparency / Reduce Motion. Views register through `addObserver` and repaint
/// from that callback instead.
@MainActor
enum TaskbarAppearance {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }

    /// Windows 10's solid taskbar grey, used in place of vibrancy under Reduce Transparency.
    static let opaqueBackground = NSColor(srgbRed: 0x1F / 255, green: 0x1F / 255, blue: 0x1F / 255, alpha: 1)

    /// Short fade that stands in for slides and pulses when Reduce Motion is on.
    static let reducedMotionFade: TimeInterval = 0.12

    /// Calls `selector` whenever the accent colour or the accessibility display options change.
    /// Selector-based observers are dropped automatically when `observer` deallocates.
    static func addObserver(_ observer: Any, selector: Selector) {
        NotificationCenter.default.addObserver(
            observer,
            selector: selector,
            name: NSColor.systemColorsDidChangeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            observer,
            selector: selector,
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
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
