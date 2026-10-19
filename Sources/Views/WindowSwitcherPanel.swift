import AppKit

/// The ⌘Tab window switcher: every taskbar window as a thumbnail, one card per app.
///
/// Driven by `WindowSwitcherHotkey`. The panel never activates this app or becomes
/// key — the app being switched away from keeps focus until the switch commits.
@MainActor
final class WindowSwitcherController {
    static let shared = WindowSwitcherController()

    /// A ⌘ release inside this window after the first Tab is a quick flip back to
    /// the previous window, and the panel never flashes up for it.
    private static let appearDelay: TimeInterval = 0.08

    private(set) var isEngaged = false
    private var groups: [[WindowInfo]] = []
    /// Display order: groups left to right, top to bottom, then windows in a group.
    private var items: [WindowInfo] = []
    private var selection = 0
    private var panel: WindowSwitcherPanel?
    private var appearTimer: Timer?
    /// Pointer position when the panel appeared; hovering only selects once it moves,
    /// so a pointer that happens to rest where the panel opens steals nothing.
    private var pointerAtShow: NSPoint?

    private init() {
        WindowThumbnailCache.shared.addListener { [weak self] windowID, image in
            guard let self, self.isEngaged else { return }
            self.panel?.content.setThumbnail(image, for: windowID)
        }
    }

    // MARK: - Driven by the hotkey

    func open(reverse: Bool) {
        guard !isEngaged else { return }
        let hidden = Set(TaskbarSettings.shared.hiddenBundleIDs)
        let windows = WindowManager.shared.windows.filter { info in
            info.bundleID.map { !hidden.contains($0) } ?? true
        }
        guard !windows.isEmpty else { return }
        WindowPreviewController.shared.hide()

        // Most recent first; windows never seen active keep their taskbar order behind
        // the rest. The current window leads — taken from the frontmost app, not the
        // taskbar's `isActive`, which holds on to the last clicked button for a moment
        // after a switch, so a quick second ⌘Tab would "flip back" to where it already is.
        var rank: [String: Int] = [:]
        for (index, id) in WindowManager.shared.recentWindowIDs.enumerated() where rank[id] == nil {
            rank[id] = index
        }
        let unseen = rank.count
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let frontWindows = windows.filter { $0.pid == frontPID }
        let current = frontWindows.first(where: \.isActive)
            ?? frontWindows.min { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
        let recent = windows.enumerated().map { offset, info in
            (info, info.id == current?.id ? -1 : rank[info.id] ?? unseen + offset)
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)

        var groups: [[WindowInfo]] = []
        var groupIndex: [pid_t: Int] = [:]
        for info in recent {
            if let index = groupIndex[info.pid] {
                groups[index].append(info)
            } else {
                groupIndex[info.pid] = groups.count
                groups.append([info])
            }
        }
        // Stable partition: minimized windows last in their group, still by recency.
        self.groups = groups.map { $0.filter { !$0.isMinimized } + $0.filter(\.isMinimized) }
        items = self.groups.flatMap { $0 }

        let initial: WindowInfo
        if reverse {
            initial = items[items.count - 1]
        } else {
            initial = recent.count > 1 && recent[0].id == current?.id ? recent[1] : recent[0]
        }
        selection = items.firstIndex { $0.id == initial.id } ?? 0
        isEngaged = true

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let panel = self.panel ?? makePanel()
        self.panel = panel
        layOut(panel, on: screen)

        let timer = Timer(timeInterval: Self.appearDelay, repeats: false) { [weak self] _ in
            // Added to the main run loop below.
            MainActor.assumeIsolated { self?.show() }
        }
        RunLoop.main.add(timer, forMode: .common)
        appearTimer = timer
    }

    func step(_ delta: Int) {
        guard isEngaged, !items.isEmpty else { return }
        select((selection + delta + items.count) % items.count)
    }

    func moveVertically(up: Bool) {
        guard isEngaged, let target = panel?.content.cellIndex(verticallyFrom: selection, up: up) else { return }
        select(target)
    }

    func commit() {
        guard isEngaged, items.indices.contains(selection) else { return }
        let info = items[selection]
        AppLog.info("DBG commit", ["sel": "\(info.appName)/\(info.title)/\(info.id)", "items": items.map { "\($0.appName):\($0.id)" }.joined(separator: ","), "mru": WindowManager.shared.recentWindowIDs.prefix(4).joined(separator: ","), "front": NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"])
        close()
        WindowManager.shared.activateWindow(info)
    }

    func cancel() {
        guard isEngaged else { return }
        close()
    }

    /// Middle-click: close that window and keep switching among the rest, as on Windows.
    private func closeWindow(at index: Int) {
        guard isEngaged, items.indices.contains(index), let panel else { return }
        WindowManager.shared.closeWindow(items[index])
        let id = items[index].id
        groups = groups.map { $0.filter { $0.id != id } }.filter { !$0.isEmpty }
        items = groups.flatMap { $0 }
        guard !items.isEmpty else {
            cancel()
            return
        }
        if selection > index || selection == items.count {
            selection -= 1
        }
        layOut(panel, on: panel.screen ?? NSScreen.main ?? NSScreen.screens[0])
    }

    /// Sizes the content for the current groups and centres the panel on `screen`.
    private func layOut(_ panel: WindowSwitcherPanel, on screen: NSScreen) {
        let size = panel.content.configure(
            groups: groups,
            selection: selection,
            maxSize: NSSize(width: screen.frame.width * 0.9, height: screen.frame.height * 0.9)
        )
        panel.setFrame(NSRect(
            x: (screen.frame.midX - size.width / 2).rounded(),
            y: (screen.frame.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        ), display: panel.isVisible)
    }

    // MARK: - Presentation

    private func show() {
        appearTimer = nil
        guard isEngaged, let panel else { return }
        pointerAtShow = NSEvent.mouseLocation
        panel.orderFrontRegardless()
        guard WindowThumbnails.isAvailable else { return }
        let scale = panel.screen?.backingScaleFactor ?? 2
        for (index, info) in items.enumerated() {
            WindowThumbnailCache.shared.capture(info, size: panel.content.thumbnailSize(at: index), scale: scale)
        }
    }

    private func close() {
        isEngaged = false
        appearTimer?.invalidate()
        appearTimer = nil
        pointerAtShow = nil
        panel?.orderOut(nil)
        panel?.content.clear()
        items = []
        WindowThumbnailCache.shared.prune(keeping: Set(WindowManager.shared.windows.compactMap(\.cgWindowID)))
    }

    private func select(_ index: Int) {
        guard index != selection else { return }
        selection = index
        panel?.content.setSelection(index)
    }

    private func makePanel() -> WindowSwitcherPanel {
        let panel = WindowSwitcherPanel()
        panel.content.onHover = { [weak self] index in
            guard let self, self.isEngaged, let start = self.pointerAtShow,
                  NSEvent.mouseLocation != start else { return }
            self.select(index)
        }
        panel.content.onClick = { [weak self] index in
            guard let self, self.isEngaged else { return }
            self.select(index)
            self.commit()
        }
        panel.content.onMiddleClick = { [weak self] index in
            self?.closeWindow(at: index)
        }
        return panel
    }
}

/// Never key or main, so showing it and clicking it leave focus where it was.
private final class WindowSwitcherPanel: NSPanel {
    let content = WindowSwitcherView()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = false
        level = .popUpMenu
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lays the groups out by hand: one pass of arithmetic per open, no constraints.
private final class WindowSwitcherView: NSView {
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    var onMiddleClick: ((Int) -> Void)?

    private enum Metrics {
        static let outerPadding: CGFloat = 14
        static let groupPadding: CGFloat = 8
        static let groupSpacing: CGFloat = 10
        static let headerHeight: CGFloat = 24
        static let minimumGroupWidth: CGFloat = 150
        static let cellPadding: CGFloat = 6
        static let cellSpacing: CGFloat = 4
        static let titleHeight: CGFloat = 16
        static let thumbnailHeight: CGFloat = 120
        static let thumbnailWidthRange: ClosedRange<CGFloat> = 80...220
        static let minimumScale: CGFloat = 0.35
    }

    private let effect = NSVisualEffectView()
    private let tint = NSView()
    private var groupViews: [NSView] = []
    private var cells: [WindowSwitcherCell] = []
    private var selection = 0

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
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

        TaskbarAppearance.addObserver(self, selector: #selector(accentChanged))
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func accentChanged() {
        for cell in cells { cell.refreshSelection() }
    }

    /// Builds the views for `groups` and returns the panel size, scaled down
    /// uniformly until it fits `maxSize`.
    func configure(groups: [[WindowInfo]], selection: Int, maxSize: NSSize) -> NSSize {
        clear()
        self.selection = selection
        let aspects = groups.map { $0.map { WindowPreviewView.aspectRatio(of: $0.cgWindowID) ?? 1.6 } }

        var scale: CGFloat = 1
        var layout = Self.layout(aspects: aspects, scale: scale, maxWidth: maxSize.width)
        while layout.size.height > maxSize.height, scale > Metrics.minimumScale {
            scale = max(scale * 0.9, Metrics.minimumScale)
            layout = Self.layout(aspects: aspects, scale: scale, maxWidth: maxSize.width)
        }

        var index = 0
        for (groupIndex, group) in groups.enumerated() {
            guard let first = group.first else { continue }
            let icon = NSRunningApplication(processIdentifier: first.pid)?.icon
                ?? first.bundleID.flatMap { PinManager.icon(forBundleID: $0) }
            let groupView = WindowSwitcherGroupView(
                frame: layout.groupFrames[groupIndex],
                icon: icon,
                appName: first.appName,
                windowCount: group.count
            )
            addSubview(groupView)
            groupViews.append(groupView)
            for info in group {
                let frame = layout.cellFrames[index]
                let cell = WindowSwitcherCell(
                    frame: frame,
                    index: index,
                    info: info,
                    icon: icon,
                    thumbnailSize: Self.thumbnailSize(forCell: frame.size, scale: scale),
                    scale: scale
                )
                cell.image = WindowThumbnailCache.shared.image(for: info.cgWindowID)
                cell.isSelected = index == selection
                cell.onHover = { [weak self] in self?.onHover?($0) }
                cell.onClick = { [weak self] in self?.onClick?($0) }
                cell.onMiddleClick = { [weak self] in self?.onMiddleClick?($0) }
                addSubview(cell)
                cells.append(cell)
                index += 1
            }
        }
        setFrameSize(layout.size)
        effect.frame = bounds
        tint.frame = bounds
        return layout.size
    }

    func clear() {
        for view in groupViews { view.removeFromSuperview() }
        for cell in cells { cell.removeFromSuperview() }
        groupViews = []
        cells = []
    }

    func setSelection(_ index: Int) {
        if cells.indices.contains(selection) { cells[selection].isSelected = false }
        selection = index
        if cells.indices.contains(index) { cells[index].isSelected = true }
    }

    func setThumbnail(_ image: NSImage, for windowID: CGWindowID) {
        for cell in cells where cell.info.cgWindowID == windowID {
            cell.image = image
        }
    }

    func thumbnailSize(at index: Int) -> NSSize {
        cells.indices.contains(index) ? cells[index].thumbnailSize : .zero
    }

    /// The cell in the nearest line above or below `index` closest to it horizontally.
    func cellIndex(verticallyFrom index: Int, up: Bool) -> Int? {
        guard cells.indices.contains(index) else { return nil }
        let current = cells[index].frame
        // Flipped: up is smaller y.
        let candidates = cells.filter { up ? $0.frame.maxY <= current.minY + 1 : $0.frame.minY >= current.maxY - 1 }
        guard let lineY = up ? candidates.map(\.frame.minY).max() : candidates.map(\.frame.minY).min() else { return nil }
        return candidates
            .filter { abs($0.frame.minY - lineY) < 1 }
            .min { abs($0.frame.midX - current.midX) < abs($1.frame.midX - current.midX) }?
            .index
    }

    private static func thumbnailSize(forCell size: NSSize, scale: CGFloat) -> NSSize {
        NSSize(
            width: size.width - Metrics.cellPadding * 2,
            height: (Metrics.thumbnailHeight * scale).rounded()
        )
    }

    private struct Layout {
        var size: NSSize
        var groupFrames: [NSRect]
        var cellFrames: [NSRect]
    }

    /// Cells wrap inside a group that is wider than the panel; groups flow left to
    /// right and wrap into rows, top-aligned.
    private static func layout(aspects: [[CGFloat]], scale: CGFloat, maxWidth: CGFloat) -> Layout {
        let thumbHeight = (Metrics.thumbnailHeight * scale).rounded()
        let cellHeight = Metrics.cellPadding * 2 + thumbHeight + 4 + Metrics.titleHeight
        let innerMax = maxWidth - Metrics.outerPadding * 2
        let groupInnerMax = innerMax - Metrics.groupPadding * 2

        // Each group's cells relative to the group's own origin.
        var groupSizes: [NSSize] = []
        var relativeCells: [[NSRect]] = []
        for group in aspects {
            var frames: [NSRect] = []
            var x: CGFloat = 0
            var y: CGFloat = 0
            var widest: CGFloat = 0
            for aspect in group {
                let range = Metrics.thumbnailWidthRange
                let thumbWidth = (min(max(thumbHeight * aspect, range.lowerBound * scale), range.upperBound * scale)).rounded()
                let width = min(thumbWidth + Metrics.cellPadding * 2, groupInnerMax)
                if x > 0, x + width > groupInnerMax {
                    x = 0
                    y += cellHeight + Metrics.cellSpacing
                }
                frames.append(NSRect(x: x, y: y, width: width, height: cellHeight))
                x += width + Metrics.cellSpacing
                widest = max(widest, x - Metrics.cellSpacing)
            }
            let width = min(max(widest + Metrics.groupPadding * 2, Metrics.minimumGroupWidth), innerMax)
            let height = Metrics.groupPadding * 2 + Metrics.headerHeight + y + cellHeight
            groupSizes.append(NSSize(width: width, height: height))
            relativeCells.append(frames)
        }

        var groupFrames: [NSRect] = []
        var cellFrames: [NSRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widestRow: CGFloat = 0
        for (index, size) in groupSizes.enumerated() {
            if x > 0, x + size.width > innerMax {
                x = 0
                y += rowHeight + Metrics.groupSpacing
                rowHeight = 0
            }
            let origin = NSPoint(x: Metrics.outerPadding + x, y: Metrics.outerPadding + y)
            groupFrames.append(NSRect(origin: origin, size: size))
            for frame in relativeCells[index] {
                cellFrames.append(frame.offsetBy(
                    dx: origin.x + Metrics.groupPadding,
                    dy: origin.y + Metrics.groupPadding + Metrics.headerHeight
                ))
            }
            x += size.width + Metrics.groupSpacing
            widestRow = max(widestRow, x - Metrics.groupSpacing)
            rowHeight = max(rowHeight, size.height)
        }
        return Layout(
            size: NSSize(width: widestRow + Metrics.outerPadding * 2, height: y + rowHeight + Metrics.outerPadding * 2),
            groupFrames: groupFrames,
            cellFrames: cellFrames
        )
    }
}

/// One app's card: its icon, name and window count above the cells, which are
/// siblings laid over it rather than children so all cells share one coordinate space.
private final class WindowSwitcherGroupView: NSView {
    override var isFlipped: Bool { true }

    init(frame: NSRect, icon: NSImage?, appName: String, windowCount: Int) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor

        let iconView = NSImageView(frame: NSRect(x: 8, y: 9, width: 16, height: 16))
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        let title = NSMutableAttributedString(string: appName, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ])
        title.append(NSAttributedString(string: "  \(windowCount)", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]))
        let label = NSTextField(labelWithAttributedString: title)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: iconView.frame.maxX + 6, y: 9, width: bounds.width - iconView.frame.maxX - 14, height: 16)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// One window: thumbnail (or app icon until one lands) with its title under it.
private final class WindowSwitcherCell: NSView {
    let index: Int
    let info: WindowInfo
    let thumbnailSize: NSSize
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    var onMiddleClick: ((Int) -> Void)?

    var image: NSImage? {
        didSet {
            thumbnailView.image = image
            placeholderView.isHidden = image != nil
        }
    }

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            refreshSelection()
        }
    }

    private let thumbnailView = NSImageView()
    private let placeholderView = NSImageView()
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    init(frame: NSRect, index: Int, info: WindowInfo, icon: NSImage?, thumbnailSize: NSSize, scale: CGFloat) {
        self.index = index
        self.info = info
        self.thumbnailSize = thumbnailSize
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6

        let padding = (bounds.width - thumbnailSize.width) / 2
        let area = NSRect(x: padding, y: padding, width: thumbnailSize.width, height: thumbnailSize.height)
        thumbnailView.frame = area
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(thumbnailView)

        let iconSize = (48 * scale).rounded()
        placeholderView.frame = NSRect(x: area.midX - iconSize / 2, y: area.midY - iconSize / 2, width: iconSize, height: iconSize)
        placeholderView.image = icon
        placeholderView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(placeholderView)

        let title = NSTextField(labelWithString: info.title.isEmpty ? info.appName : info.title)
        title.font = .systemFont(ofSize: 11)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.alignment = .center
        title.frame = NSRect(x: 4, y: area.maxY + 4, width: bounds.width - 8, height: 16)
        addSubview(title)

        if info.isMinimized {
            thumbnailView.alphaValue = 0.5
            placeholderView.alphaValue = 0.5
            title.alphaValue = 0.6
        }
        refreshSelection()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refreshSelection() {
        layer?.borderWidth = isSelected ? 2 : 0
        layer?.borderColor = resolvedCGColor(.controlAccentColor)
        layer?.backgroundColor = NSColor.white.withAlphaComponent(isSelected ? 0.14 : 0).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(index) }
    override func mouseMoved(with event: NSEvent) { onHover?(index) }

    /// The panel never activates this app, so the first click must count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?(index)
    }

    override func otherMouseDown(with event: NSEvent) {}

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onMiddleClick?(index)
    }
}
