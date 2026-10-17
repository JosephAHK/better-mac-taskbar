import AppKit

/// Windows-10-style flyout above a task button: the window's title, a close button
/// and — when Screen Recording is granted — a thumbnail refreshed about once a second.
///
/// Hover drives it: it opens after a short rest on a button, moves straight to the
/// next button while open, and closes shortly after the pointer leaves both the
/// button and the flyout. An auto-hidden bar has to finish sliding in first, so the
/// flyout is never placed against a bar that is still moving. The panel is non-activating and can never become key, so
/// hovering never pulls focus from the app the user is in.
@MainActor
final class WindowPreviewController {
    static let shared = WindowPreviewController()

    /// Long enough to cross the gap between a button and the flyout above it.
    private static let hideDelay: TimeInterval = 0.15
    private static let thumbnailRefreshInterval: TimeInterval = 1

    private var panel: WindowPreviewPanel?
    private weak var anchor: TaskButtonView?
    /// The button a scheduled show is waiting on.
    private weak var pendingAnchor: TaskButtonView?
    /// Clicking a window's button activates it; the preview stays away until the
    /// pointer leaves that button rather than popping straight back up.
    private weak var suppressedAnchor: TaskButtonView?
    private var showTimer: Timer?
    private var hideTimer: Timer?
    private var refreshTimer: Timer?
    private var thumbnails: [CGWindowID: NSImage] = [:]
    private var capturesInFlight: Set<CGWindowID> = []
    /// Tracked on its own rather than read off the panel's visibility, so the
    /// keep-visible hold is released exactly once even if AppKit ordered the panel
    /// out behind our back — a leaked hold would switch auto-hide off for good.
    private var holdsBar = false

    var isVisible: Bool { panel?.isVisible == true }

    private init() {
        // Button style and the previews switch itself both change what the flyout should
        // look like; it is transient, so closing it is the simplest correct response.
        NotificationCenter.default.addObserver(forName: .taskbarSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    // MARK: - Driven by task buttons

    func pointerEntered(_ button: TaskButtonView) {
        if isVisible, anchor === button {
            // Back from the flyout to its own button.
            cancelHide()
            return
        }
        if showTimer != nil, pendingAnchor === button { return }
        // A held button means an icon is being dragged to reorder it. Otherwise a
        // flyout that is already up follows the pointer to the next button at once.
        guard TaskbarSettings.shared.showWindowPreviews,
              suppressedAnchor !== button,
              NSEvent.pressedMouseButtons == 0 else { return }
        if isVisible {
            cancelHide()
            show(for: button)
        } else {
            scheduleShow(for: button)
        }
    }

    func pointerExited(_ button: TaskButtonView) {
        if suppressedAnchor === button {
            suppressedAnchor = nil
        }
        cancelShow()
        if isVisible {
            scheduleHide()
        }
    }

    /// The button's click activated a window.
    func dismissAfterClick(on button: TaskButtonView) {
        hide()
        suppressedAnchor = button
    }

    /// The anchor's window changed: its title, focus, badge or hung state.
    func buttonDidUpdate(_ button: TaskButtonView) {
        guard isVisible, anchor === button else { return }
        show(for: button)
    }

    func buttonDidDisappear(_ button: TaskButtonView) {
        if anchor === button {
            hide()
        }
        if showTimer != nil, pendingAnchor === button {
            cancelShow()
        }
    }

    /// The bar `window` is about to slide, fade or be reframed, so anything placed
    /// against its current position is about to be wrong.
    func barWillMove(_ window: NSWindow) {
        if anchor?.window === window {
            hide()
        }
        if pendingAnchor?.window === window {
            cancelShow()
        }
    }

    /// An auto-hidden bar finished sliding in. The pointer may have come to rest on a
    /// button during the slide, and a view moving under a still pointer gets no
    /// mouseEntered, so look for the button under it now.
    func barDidSettle(_ window: NSWindow) {
        guard TaskbarSettings.shared.showWindowPreviews, anchor == nil, showTimer == nil,
              NSEvent.pressedMouseButtons == 0 else { return }
        var view = window.contentView?.hitTest(window.convertPoint(fromScreen: NSEvent.mouseLocation))
        while let candidate = view, !(candidate is TaskButtonView) {
            view = candidate.superview
        }
        guard let button = view as? TaskButtonView, suppressedAnchor !== button else { return }
        scheduleShow(for: button)
    }

    func hide() {
        cancelShow()
        cancelHide()
        refreshTimer?.invalidate()
        refreshTimer = nil
        anchor = nil
        thumbnails.removeAll()
        panel?.orderOut(nil)
        if holdsBar {
            holdsBar = false
            TaskbarPanelController.shared.endKeepVisible()
        }
    }

    // MARK: - Timers

    /// The delay starts once the button's bar has settled; until then `barDidSettle`
    /// picks the hover back up.
    private func scheduleShow(for button: TaskButtonView) {
        cancelShow()
        guard let barWindow = button.window, TaskbarPanelController.shared.isSettled(barWindow) else { return }
        let delay = TaskbarSettings.shared.windowPreviewDelay
        if delay <= 0 {
            show(for: button)
            return
        }
        pendingAnchor = button
        showTimer = scheduledTimer(after: delay) { [weak self, weak button] in
            guard let self else { return }
            self.showTimer = nil
            guard let button, button.window != nil, NSEvent.pressedMouseButtons == 0 else { return }
            self.show(for: button)
        }
    }

    private func cancelShow() {
        showTimer?.invalidate()
        showTimer = nil
        pendingAnchor = nil
    }

    private func scheduleHide() {
        guard hideTimer == nil else { return }
        hideTimer = scheduledTimer(after: Self.hideDelay) { [weak self] in
            guard let self else { return }
            self.hideTimer = nil
            // Exit events can be missed (a menu or a drag in between), so look at
            // where the pointer actually is before closing.
            if !self.isPointerOverPreviewOrAnchor {
                self.hide()
            }
        }
    }

    private func cancelHide() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private var isPointerOverPreviewOrAnchor: Bool {
        let point = NSEvent.mouseLocation
        if let panel, panel.frame.contains(point) { return true }
        guard let anchor, let window = anchor.window else { return false }
        return window.convertToScreen(anchor.convert(anchor.bounds, to: nil)).contains(point)
    }

    /// `.common` so the timers also fire while a menu or drag is tracking.
    private func scheduledTimer(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            // Added to the main run loop below.
            MainActor.assumeIsolated { action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    // MARK: - Presentation

    private func show(for button: TaskButtonView) {
        guard let barWindow = button.window, let screen = barWindow.screen,
              TaskbarPanelController.shared.isSettled(barWindow) else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        anchor = button

        let gutter = PanelMetrics.flyoutEdgeGutter
        let info = button.windowInfo
        let showsThumbnails = WindowThumbnails.isAvailable
        panel.preview.configure(
            window: info,
            notResponding: button.isNotResponding,
            showsThumbnail: showsThumbnails,
            thumbnail: info.cgWindowID.flatMap { thumbnails[$0] },
            showsThumbnailHint: !showsThumbnails && WindowThumbnails.isSupported
        )

        let size = panel.preview.frame.size
        let buttonFrame = barWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let x = min(
            max(buttonFrame.midX - size.width / 2, screen.frame.minX + gutter),
            screen.frame.maxX - gutter - size.width
        )
        panel.setFrame(NSRect(x: x, y: buttonFrame.maxY + gutter, width: size.width, height: size.height), display: true)

        if !holdsBar {
            holdsBar = true
            TaskbarPanelController.shared.beginKeepVisible()
        }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
            AppLog.debug("window preview shown", ["thumbnails": showsThumbnails])
        }

        if showsThumbnails {
            if refreshTimer == nil {
                let timer = Timer(timeInterval: Self.thumbnailRefreshInterval, repeats: true) { [weak self] _ in
                    // Added to the main run loop below.
                    MainActor.assumeIsolated { self?.captureThumbnails() }
                }
                RunLoop.main.add(timer, forMode: .common)
                refreshTimer = timer
            }
            captureThumbnails()
        }
    }

    private func makePanel() -> WindowPreviewPanel {
        let panel = WindowPreviewPanel()
        panel.preview.onPointerEntered = { [weak self] in self?.cancelHide() }
        panel.preview.onPointerExited = { [weak self] in self?.scheduleHide() }
        panel.preview.onActivate = { [weak self] info in
            WindowManager.shared.activateWindow(info)
            guard let self else { return }
            if let anchor = self.anchor {
                self.dismissAfterClick(on: anchor)
            } else {
                self.hide()
            }
        }
        panel.preview.onShowThumbnailSettings = { [weak self] in
            self?.hide()
            SettingsWindowController.shared.show(page: .appearance)
        }
        panel.preview.onClose = { info in
            // The card goes when the window does, through buttonDidUpdate; a window
            // that asks to save first stays listed until it actually closes.
            WindowManager.shared.closeWindow(info)
        }
        return panel
    }

    // MARK: - Thumbnails

    private func captureThumbnails() {
        guard #available(macOS 14.0, *), let panel, WindowThumbnails.isAvailable,
              let windowID = anchor?.windowInfo.cgWindowID,
              capturesInFlight.insert(windowID).inserted else { return }
        let scale = panel.backingScaleFactor
        let thumbnailSize = panel.preview.thumbnailSize
        Task {
            let image = await WindowThumbnailer.shared.image(
                of: windowID,
                fitting: thumbnailSize,
                scale: scale
            )
            self.thumbnailArrived(image, for: windowID, scale: scale)
        }
    }

    private func thumbnailArrived(_ image: CGImage?, for windowID: CGWindowID, scale: CGFloat) {
        capturesInFlight.remove(windowID)
        // Captures finish after the flyout moved on or closed; those are dropped.
        guard let image, isVisible, anchor?.windowInfo.cgWindowID == windowID else { return }
        let thumbnail = NSImage(
            cgImage: image,
            size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        )
        thumbnails[windowID] = thumbnail
        panel?.preview.setThumbnail(thumbnail, for: windowID)
    }
}

/// Never key or main: clicks on the cards act without activating this app.
private final class WindowPreviewPanel: NSPanel {
    let preview = WindowPreviewView()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = false
        level = .statusBar
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        // A window shadow is recomputed from the content each time the cards change,
        // which flickers as thumbnails stream in; the flyout draws its own edge instead.
        hasShadow = false
        // Same Spaces behaviour as the bar it hangs off.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)
        contentView = preview
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The flyout's content: one card for the window, with the Screen Recording hint
/// under it when thumbnails could be had but aren't.
final class WindowPreviewView: NSView {
    var onPointerEntered: (() -> Void)?
    var onPointerExited: (() -> Void)?
    var onActivate: ((WindowInfo) -> Void)?
    var onClose: ((WindowInfo) -> Void)?
    var onShowThumbnailSettings: (() -> Void)?

    /// The window's own shape fitted inside the Thumbnail size box (the set width,
    /// at most 3:4 of it tall), so the card hugs the image instead of letterboxing a
    /// fixed box. Read from the window server, which knows the frame before any
    /// capture lands.
    static func thumbnailSize(for info: WindowInfo) -> NSSize {
        let maxWidth = TaskbarSettings.shared.previewThumbnailWidth
        let maxHeight = (maxWidth * 0.75).rounded()
        guard let aspect = aspectRatio(of: info.cgWindowID) else {
            return NSSize(width: maxWidth, height: (maxWidth * 0.625).rounded())
        }
        if aspect >= maxWidth / maxHeight {
            return NSSize(width: maxWidth, height: (maxWidth / aspect).rounded())
        }
        return NSSize(width: (maxHeight * aspect).rounded(), height: maxHeight)
    }

    private static func aspectRatio(of windowID: CGWindowID?) -> CGFloat? {
        guard let windowID,
              let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? [String: CGFloat],
              let width = bounds["Width"], let height = bounds["Height"],
              width > 0, height > 0 else { return nil }
        return width / height
    }
    private static let padding: CGFloat = 8

    private let effect = NSVisualEffectView()
    private let tint = NSView()
    private var card: WindowPreviewCard?
    /// Image area of the current card; captures are taken at this size.
    private(set) var thumbnailSize = NSSize.zero
    private var tracking: NSTrackingArea?
    /// Shown instead of a thumbnail while Screen Recording isn't granted: without it
    /// the title card gives no hint that images are possible, or where to turn them on.
    /// Made on first use, since most setups either have thumbnails or never will.
    private var thumbnailHint: NSButton?
    private static let hintHeight: CGFloat = 18

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)

        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        addSubview(tint)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Rebuilds the card and sizes the view to fit it. Without `showsThumbnail` the
    /// card drops its image area altogether.
    func configure(
        window info: WindowInfo,
        notResponding: Bool,
        showsThumbnail: Bool,
        thumbnail: NSImage?,
        showsThumbnailHint: Bool
    ) {
        card?.removeFromSuperview()
        thumbnailSize = Self.thumbnailSize(for: info)
        let card = WindowPreviewCard(
            info: info,
            notResponding: notResponding,
            thumbnailSize: showsThumbnail ? thumbnailSize : nil
        )
        card.onActivate = { [weak self] in self?.onActivate?(info) }
        card.onClose = { [weak self] in self?.onClose?(info) }
        if let thumbnail {
            card.setThumbnail(thumbnail)
        }
        addSubview(card)
        self.card = card

        // The hint sits below the card.
        let hintSpace = showsThumbnailHint ? Self.hintHeight : 0
        let hintWidth = showsThumbnailHint ? makeThumbnailHint().frame.width : 0
        let cardSize = card.frame.size
        setFrameSize(NSSize(
            width: max(cardSize.width, hintWidth) + Self.padding * 2,
            height: cardSize.height + Self.padding * 2 + hintSpace
        ))
        card.setFrameOrigin(NSPoint(x: Self.padding, y: Self.padding + hintSpace))
        effect.frame = bounds
        tint.frame = bounds
        if showsThumbnailHint, let hint = thumbnailHint {
            hint.isHidden = false
            hint.setFrameOrigin(NSPoint(x: Self.padding - 2, y: Self.padding / 2))
        } else {
            thumbnailHint?.isHidden = true
        }
    }

    private func makeThumbnailHint() -> NSButton {
        if let thumbnailHint { return thumbnailHint }
        let button = FirstMouseButton(title: "Show window thumbnails…", target: self, action: #selector(showThumbnailSettings))
        button.isBordered = false
        button.font = .systemFont(ofSize: 11)
        button.contentTintColor = .controlAccentColor
        button.toolTip = "Thumbnails need Screen Recording permission"
        button.sizeToFit()
        addSubview(button)
        thumbnailHint = button
        return button
    }

    @objc private func showThumbnailSettings() {
        onShowThumbnailSettings?()
    }

    func setThumbnail(_ image: NSImage, for windowID: CGWindowID) {
        guard let card, card.info.cgWindowID == windowID else { return }
        card.setThumbnail(image)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onPointerEntered?() }
    override func mouseExited(with event: NSEvent) { onPointerExited?() }
}

/// One window in the flyout. Click switches to it; × closes it.
private final class WindowPreviewCard: NSView {
    let info: WindowInfo
    var onActivate: (() -> Void)?
    var onClose: (() -> Void)?

    /// Narrow or tall windows still leave room for the title and close button.
    private static let minimumThumbnailCardWidth: CGFloat = 180
    private static let titleOnlyWidth: CGFloat = 260
    private static let headerHeight: CGFloat = 28
    private static let placeholderIconSize: CGFloat = 48

    private let showsThumbnail: Bool
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = FirstMouseButton()
    private let thumbnailView = NSImageView()
    /// Stands in for the thumbnail until the first capture lands, or for windows that
    /// can't be captured (minimized ones, often).
    private let placeholderView = NSImageView()
    private var tracking: NSTrackingArea?
    private var isHovered = false

    /// `thumbnailSize` nil means a title-only card.
    init(info: WindowInfo, notResponding: Bool, thumbnailSize: NSSize?) {
        self.info = info
        self.showsThumbnail = thumbnailSize != nil
        let width = thumbnailSize.map { max($0.width + 16, Self.minimumThumbnailCardWidth) } ?? Self.titleOnlyWidth
        let height = thumbnailSize.map { Self.headerHeight + $0.height + 8 } ?? Self.headerHeight
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.cornerRadius = 5

        let icon = NSRunningApplication(processIdentifier: info.pid)?.icon
            ?? info.bundleID.flatMap { PinManager.icon(forBundleID: $0) }
        let headerY = bounds.height - Self.headerHeight

        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.frame = NSRect(x: 8, y: headerY + 6, width: 16, height: 16)
        addSubview(iconView)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close window"
        closeButton.frame = NSRect(x: bounds.width - 26, y: headerY + 4, width: 20, height: 20)
        addSubview(closeButton)

        titleLabel.stringValue = notResponding ? "\(info.displayTitle) (Not responding)" : info.displayTitle
        titleLabel.font = NSFont.systemFont(ofSize: 12)
        titleLabel.textColor = notResponding ? .secondaryLabelColor : .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(x: iconView.frame.maxX + 6, y: headerY + 6, width: closeButton.frame.minX - iconView.frame.maxX - 10, height: 16)
        addSubview(titleLabel)

        if let thumbnailSize {
            let area = NSRect(
                x: ((bounds.width - thumbnailSize.width) / 2).rounded(),
                y: 4,
                width: thumbnailSize.width,
                height: thumbnailSize.height
            )
            thumbnailView.frame = area
            thumbnailView.imageScaling = .scaleProportionallyDown
            addSubview(thumbnailView)

            placeholderView.image = icon
            placeholderView.imageScaling = .scaleProportionallyUpOrDown
            placeholderView.frame = NSRect(
                x: area.midX - Self.placeholderIconSize / 2,
                y: area.midY - Self.placeholderIconSize / 2,
                width: Self.placeholderIconSize,
                height: Self.placeholderIconSize
            )
            placeholderView.alphaValue = info.isMinimized ? 0.5 : 0.8
            addSubview(placeholderView)
        }
        refreshBackground()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setThumbnail(_ image: NSImage) {
        guard showsThumbnail else { return }
        thumbnailView.image = image
        placeholderView.isHidden = true
    }

    private func refreshBackground() {
        let alpha: CGFloat
        if isHovered {
            alpha = 0.16
        } else {
            alpha = info.isActive ? 0.08 : 0
        }
        layer?.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshBackground()
    }

    /// The panel never activates this app, so the first click must count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onActivate?()
    }

    // Middle-click closes, as on the task button itself. Acted on at release over
    // the card, like a normal click, so pressing and dragging off cancels it.
    override func otherMouseDown(with event: NSEvent) {}

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClose?()
    }

    @objc private func closeClicked() {
        onClose?()
    }

}

/// The flyout never activates this app, so its window is never key; the close button
/// has to act on the first click rather than treat it as a focusing click.
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
