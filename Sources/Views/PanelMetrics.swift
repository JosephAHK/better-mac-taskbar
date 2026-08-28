import AppKit

/// Layout constants shared by the tray flyout panels (Downloads, Trash).
enum PanelMetrics {
    /// Horizontal strip at a scrolling row's trailing edge that must stay free of
    /// interactive controls.
    ///
    /// macOS overlay scrollers are drawn *on top of* the document view rather than
    /// taking layout space, so a button pinned flush to a row's right edge ends up
    /// underneath the scroller and stops being clickable whenever it is visible.
    /// Right-aligned row controls are inset by this much to sit inboard of it.
    static let scrollerGutter: CGFloat = 16
}
