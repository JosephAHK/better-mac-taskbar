import AppKit
import ApplicationServices

final class TaskbarContentView: NSView {
    private let startButton = StartButtonView()
    private let tasksContainer = NSView()
    private let tray = TrayView()
    private let startMenu = StartMenuController()
    private var startOpen = false

    private let tasksStack = NSStackView()
    private let overflowButton = TaskOverflowButtonView()
    private let overflowButtonWidth: CGFloat = 32

    private struct Slot {
        let view: NSView
        let width: NSLayoutConstraint
    }

    /// One button per strip item, keyed by `DisplayItem.slotKey`. A window-list
    /// change updates the buttons it touches in place and adds or removes only the
    /// ones that came or went, instead of rebuilding every button on every screen.
    private var slots: [String: Slot] = [:]
    /// Strip contents in display order, as of the last reload.
    private var items: [DisplayItem] = []
    /// Leading items that fit on the bar; the rest are listed by the overflow button.
    private var visibleCount = 0
    private var builtStyle: TaskbarButtonStyle = TaskbarSettings.shared.buttonStyle
    /// Container width the strip was last fitted to.
    private var fittedWidth: CGFloat = -1

    private var centeredConstraints: [NSLayoutConstraint] = []
    private var leadingConstraints: [NSLayoutConstraint] = []
    private var stackTrailing: NSLayoutConstraint?

    private weak var draggingIcon: NSView?
    private var isDraggingIcon = false
    private var dragStartLocation: NSPoint?
    private var didReorderDuringDrag = false
    private var dragMouseUpMonitor: Any?
    /// A reload arrived mid-drag. Rearranging the stack then would cancel the drag's
    /// mouse tracking, so it is replayed when the drag ends instead of being lost.
    private var needsReloadAfterDrag = false
    private let dragThreshold: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setup()
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .windowsUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .taskbarSettingsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .pinnedAppsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .hiddenAppsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .taskbarOrderChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .launchingAppsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: DockBadgeMonitor.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        // Views are only ever released on the main thread.
        MainActor.assumeIsolated { endDragMouseUpMonitor() }
        NotificationCenter.default.removeObserver(self)
    }

    private func setup() {
        startButton.translatesAutoresizingMaskIntoConstraints = false
        tasksContainer.translatesAutoresizingMaskIntoConstraints = false
        tray.translatesAutoresizingMaskIntoConstraints = false

        addSubview(startButton)
        addSubview(tasksContainer)
        addSubview(tray)

        startButton.onToggle = { [weak self] in
            self?.toggleStart()
        }
        startMenu.onHide = { [weak self] in
            self?.startOpen = false
            self?.startButton.setHighlighted(false)
        }

        tray.onShowDesktop = {
            AccessibilityService.toggleShowDesktop()
        }

        NSLayoutConstraint.activate([
            startButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            startButton.topAnchor.constraint(equalTo: topAnchor),
            startButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            startButton.widthAnchor.constraint(equalTo: heightAnchor),

            tray.trailingAnchor.constraint(equalTo: trailingAnchor),
            tray.topAnchor.constraint(equalTo: topAnchor),
            tray.bottomAnchor.constraint(equalTo: bottomAnchor),

            tasksContainer.leadingAnchor.constraint(equalTo: startButton.trailingAnchor),
            tasksContainer.trailingAnchor.constraint(equalTo: tray.leadingAnchor),
            tasksContainer.topAnchor.constraint(equalTo: topAnchor),
            tasksContainer.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        setupTasksStrip()
        reload()
    }

    private func setupTasksStrip() {
        tasksStack.orientation = .horizontal
        tasksStack.spacing = 0
        tasksStack.alignment = .centerY
        tasksStack.translatesAutoresizingMaskIntoConstraints = false
        tasksContainer.addSubview(tasksStack)

        overflowButton.translatesAutoresizingMaskIntoConstraints = false
        overflowButton.isHidden = true
        overflowButton.entriesProvider = { [weak self] in
            self?.overflowEntries() ?? []
        }
        tasksContainer.addSubview(overflowButton)

        // Center on the whole screen width (like Windows 11), not just the leftover
        // space between the Start button and tray — those two are rarely symmetric,
        // so centering within tasksContainer alone visibly drifts off true center.
        // Lower-priority centerX yields to the required containment constraints
        // below once there are enough icons to collide with Start/tray.
        let centerX = tasksStack.centerXAnchor.constraint(equalTo: centerXAnchor)
        centerX.priority = .defaultHigh
        centeredConstraints = [centerX]
        leadingConstraints = [
            tasksStack.leadingAnchor.constraint(equalTo: tasksContainer.leadingAnchor, constant: 4)
        ]

        // Containment is required in both alignments so the strip can never run
        // under the tray; fitButtons() moves whatever doesn't fit into the overflow.
        let trailing = tasksStack.trailingAnchor.constraint(lessThanOrEqualTo: tasksContainer.trailingAnchor, constant: -4)
        stackTrailing = trailing
        NSLayoutConstraint.activate([
            tasksStack.centerYAnchor.constraint(equalTo: tasksContainer.centerYAnchor),
            tasksStack.heightAnchor.constraint(equalTo: tasksContainer.heightAnchor),
            tasksStack.leadingAnchor.constraint(greaterThanOrEqualTo: tasksContainer.leadingAnchor, constant: 4),
            trailing,

            overflowButton.leadingAnchor.constraint(equalTo: tasksStack.trailingAnchor),
            overflowButton.topAnchor.constraint(equalTo: tasksContainer.topAnchor),
            overflowButton.bottomAnchor.constraint(equalTo: tasksContainer.bottomAnchor),
            overflowButton.widthAnchor.constraint(equalToConstant: overflowButtonWidth)
        ])
    }

    var isStartMenuVisible: Bool { startMenu.isVisible }

    func hideStartMenu() {
        guard startMenu.isVisible else { return }
        startMenu.hide()
        startOpen = false
        startButton.setHighlighted(false)
    }

    func toggleStartMenuFromHotkey() {
        toggleStart()
    }

    private func toggleStart() {
        startOpen.toggle()
        startButton.setHighlighted(startOpen)
        startMenu.toggle(relativeTo: startButton)
        if !startMenu.isVisible {
            startOpen = false
            startButton.setHighlighted(false)
        }
    }

    @objc func reload() {
        if isDraggingIcon {
            needsReloadAfterDrag = true
            return
        }
        needsReloadAfterDrag = false

        let center = TaskbarSettings.shared.centerIcons
        NSLayoutConstraint.deactivate(center ? leadingConstraints : centeredConstraints)
        NSLayoutConstraint.activate(center ? centeredConstraints : leadingConstraints)

        let height = bounds.height > 0 ? bounds.height : TaskbarSettings.shared.barHeight
        let style = TaskbarSettings.shared.buttonStyle
        builtStyle = style
        let newItems = Self.orderedDisplayItems()
        let badges = DockBadgeMonitor.shared
        let unresponsive = WindowManager.shared.unresponsivePIDs

        var ordered: [NSView] = []
        var liveKeys = Set<String>()
        for item in newItems {
            let key = item.slotKey
            liveKeys.insert(key)
            let slot: Slot
            if let existing = slots[key], Self.canReuse(existing.view, for: item, style: style) {
                slot = existing
            } else {
                slots[key]?.view.removeFromSuperview()
                slot = makeSlot(for: item, style: style, height: height)
                slots[key] = slot
            }
            switch item {
            case .window(let info):
                (slot.view as? TaskButtonView)?.apply(
                    info,
                    badge: badges.badge(bundleID: info.bundleID, appName: info.appName),
                    notResponding: unresponsive.contains(info.pid)
                )
            case .pinned(let bundleID), .launching(let bundleID):
                let pinned = slot.view as? PinnedButtonView
                pinned?.setLaunching(LaunchTracker.shared.isLaunching(bundleID))
                pinned?.setBadge(badges.badge(bundleID: bundleID, appName: PinManager.appName(forBundleID: bundleID)))
            }
            ordered.append(slot.view)
        }
        for key in slots.keys where !liveKeys.contains(key) {
            slots.removeValue(forKey: key)?.view.removeFromSuperview()
        }

        // Only views that are out of place move, so an unchanged strip doesn't relayout.
        for (index, view) in ordered.enumerated() {
            let arranged = tasksStack.arrangedSubviews
            if index < arranged.count, arranged[index] === view { continue }
            if arranged.contains(view) {
                tasksStack.removeArrangedSubview(view)
            }
            tasksStack.insertArrangedSubview(view, at: index)
        }

        items = newItems
        fitButtons()
    }

    /// Button style is fixed per view, so a style change needs fresh window buttons;
    /// closed pins are always square and survive it.
    private static func canReuse(_ view: NSView, for item: DisplayItem, style: TaskbarButtonStyle) -> Bool {
        switch item {
        case .window:
            return (view as? TaskButtonView)?.style == style
        case .pinned, .launching:
            return view is PinnedButtonView
        }
    }

    private func makeSlot(for item: DisplayItem, style: TaskbarButtonStyle, height: CGFloat) -> Slot {
        let view: NSView
        switch item {
        case .pinned(let bundleID), .launching(let bundleID):
            // Closed pins stay square even in Wide mode — only open windows get labels.
            let pinned = PinnedButtonView(
                bundleID: bundleID,
                height: height,
                width: height,
                style: .compact
            )
            pinned.dragDelegate = self
            pinned.onLaunch = { PinManager.launch(bundleID: $0) }
            pinned.onUnpin = { PinManager.togglePin(bundleID: $0) }
            pinned.onHide = { HideManager.toggleHidden(bundleID: $0) }
            view = pinned
        case .window(let info):
            let button = TaskButtonView(windowInfo: info, height: height, width: height, style: style)
            button.dragDelegate = self
            button.onActivate = { info in
                WindowManager.shared.activateWindow(info)
            }
            button.onClose = { info in
                WindowManager.shared.closeWindow(info)
            }
            button.onMinimize = { info in
                WindowManager.shared.minimizeWindow(info)
            }
            button.onPinToggle = { info in
                PinManager.togglePin(bundleID: info.bundleID)
            }
            button.onHideToggle = { info in
                HideManager.toggleHidden(bundleID: info.bundleID)
            }
            button.onQuit = { info in
                NSRunningApplication(processIdentifier: info.pid)?.terminate()
            }
            button.onNewWindow = { info in
                if let bid = info.bundleID {
                    PinManager.launch(bundleID: bid)
                }
            }
            view = button
        }
        // Just below required: the stack's containment constraints must win if a
        // fit is momentarily stale, rather than AppKit breaking one of them.
        let width = view.widthAnchor.constraint(equalToConstant: height)
        width.priority = NSLayoutConstraint.Priority(999)
        width.isActive = true
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return Slot(view: view, width: width)
    }

    /// Labeled window buttons share whatever space is left after closed pins take a
    /// square each. Once that slice is too narrow to read, every button is a
    /// square, and squares that still don't fit move into the overflow menu.
    private func fitButtons() {
        let height = bounds.height > 0 ? bounds.height : TaskbarSettings.shared.barHeight
        let available = availableTaskWidth()
        let windowCount = items.filter(\.isWindow).count
        let pinnedCount = items.count - windowCount

        var windowWidth = height
        visibleCount = items.count
        let labeledWidth = windowCount > 0
            ? (available - CGFloat(pinnedCount) * height) / CGFloat(windowCount)
            : 0
        if builtStyle.showsTitle, labeledWidth >= TaskbarButtonStyle.minLabeledWidth {
            windowWidth = min(labeledWidth, TaskbarButtonStyle.maxLabeledWidth)
        } else if available > 0, CGFloat(items.count) * height > available {
            visibleCount = max(Int(((available - overflowButtonWidth) / height).rounded(.down)), 0)
        }

        for (index, item) in items.enumerated() {
            guard let slot = slots[item.slotKey] else { continue }
            let width = item.isWindow ? windowWidth : height
            if abs(slot.width.constant - width) > 0.5 {
                slot.width.constant = width
            }
            // Hidden arranged views are detached from the stack's layout, so the
            // overflowed tail takes no space but keeps its place in the order.
            let overflowed = index >= visibleCount
            if slot.view.isHidden != overflowed {
                slot.view.isHidden = overflowed
            }
        }

        let overflow = items.dropFirst(visibleCount)
        overflowButton.isHidden = overflow.isEmpty
        overflowButton.containsActiveWindow = overflow.contains {
            if case .window(let info) = $0 { return info.isActive }
            return false
        }
        stackTrailing?.constant = overflow.isEmpty ? -4 : -(4 + overflowButtonWidth)
        fittedWidth = tasksContainer.bounds.width
    }

    private func availableTaskWidth() -> CGFloat {
        let width = tasksContainer.bounds.width
        if width > 0 { return width - 8 }
        // First layout pass: approximate with screen width minus Start + tray.
        let screenWidth = (window?.screen ?? NSScreen.main)?.frame.width ?? 0
        guard screenWidth > 0 else { return 0 }
        let height = bounds.height > 0 ? bounds.height : TaskbarSettings.shared.barHeight
        return max(screenWidth - height - tray.fittingSize.width - 8, 0)
    }

    private func overflowEntries() -> [TaskOverflowButtonView.Entry] {
        items.dropFirst(visibleCount).map { item in
            switch item {
            case .window(let info):
                let icon = NSRunningApplication(processIdentifier: info.pid)?.icon
                    ?? info.bundleID.flatMap { PinManager.icon(forBundleID: $0) }
                return TaskOverflowButtonView.Entry(title: info.displayTitle, icon: icon, isActive: info.isActive) {
                    WindowManager.shared.activateWindow(info)
                }
            case .pinned(let bundleID), .launching(let bundleID):
                return TaskOverflowButtonView.Entry(
                    title: PinManager.appName(forBundleID: bundleID),
                    icon: PinManager.icon(forBundleID: bundleID),
                    isActive: false
                ) {
                    PinManager.launch(bundleID: bundleID)
                }
            }
        }
    }

    private enum DisplayItem {
        case pinned(String)
        /// Unpinned app mid-launch — a placeholder slot that disappears once its
        /// first window shows up (or the launch times out).
        case launching(String)
        case window(WindowInfo)

        /// Identity of the button that shows this item. A pin's placeholder and its
        /// "opening" state share one button; its windows get their own.
        var slotKey: String {
            switch self {
            case .pinned(let bundleID), .launching(let bundleID): return "app:" + bundleID
            case .window(let info): return "window:" + info.id
            }
        }

        var isWindow: Bool {
            if case .window = self { return true }
            return false
        }

        /// Keys to try, in priority order, when looking up a persisted rank.
        /// A pinned icon is ranked by bundleID, but the moment its app launches the
        /// same slot becomes a `.window` item keyed by window id — unranked, so it
        /// would jump to the far right. Falling back to bundleID keeps the icon put.
        var rankKeys: [String] {
            switch self {
            case .pinned(let bundleID), .launching(let bundleID): return [bundleID]
            case .window(let info): return [info.id, info.bundleID].compactMap { $0 }
            }
        }
    }

    private static func orderedDisplayItems() -> [DisplayItem] {
        let windows = WindowManager.shared.windows
        let hidden = Set(TaskbarSettings.shared.hiddenBundleIDs)
        let pinnedIDs = TaskbarSettings.shared.pinnedBundleIDs.filter { !hidden.contains($0) }
        let pinnedSet = Set(pinnedIDs)
        let runningBundleIDs = Set(windows.compactMap(\.bundleID))

        // Keep each pinned app in its pin slot when it starts running. The old path
        // listed leftover pins first, then *all* windows — so a newly opened pin
        // jumped to the far right of the strip whenever taskbarOrder was empty.
        var windowsByPinnedBundle: [String: [WindowInfo]] = [:]
        var unpinnedWindows: [WindowInfo] = []
        for info in windows {
            if let bid = info.bundleID, hidden.contains(bid) { continue }
            if let bid = info.bundleID, pinnedSet.contains(bid) {
                windowsByPinnedBundle[bid, default: []].append(info)
            } else {
                unpinnedWindows.append(info)
            }
        }

        var items: [DisplayItem] = []
        for bundleID in pinnedIDs {
            if let running = windowsByPinnedBundle[bundleID], !running.isEmpty {
                items.append(contentsOf: running.map { .window($0) })
            } else {
                items.append(.pinned(bundleID))
            }
        }
        items.append(contentsOf: unpinnedWindows.map { .window($0) })

        // An app opened from the Start menu has no icon on the strip yet — give it a
        // temporary slot at the end so the opening indicator is visible somewhere.
        for bundleID in LaunchTracker.shared.launchingBundleIDs.sorted()
            where !pinnedSet.contains(bundleID)
            && !runningBundleIDs.contains(bundleID)
            && !hidden.contains(bundleID) {
            items.append(.launching(bundleID))
        }

        let order = TaskbarSettings.shared.taskbarOrder
        guard !order.isEmpty else { return items }

        var rank: [String: Int] = [:]
        for (index, key) in order.enumerated() where rank[key] == nil {
            rank[key] = index
        }

        func rankOf(_ item: DisplayItem) -> Int {
            for key in item.rankKeys {
                if let r = rank[key] { return r }
            }
            return Int.max
        }

        return items.enumerated().sorted { a, b in
            let ra = rankOf(a.element)
            let rb = rankOf(b.element)
            let aKnown = ra != Int.max
            let bKnown = rb != Int.max
            // Only compare persisted ranks when both sides have one. Otherwise keep the
            // pin-aware construction order so a first-time launch doesn't jump right.
            if aKnown, bKnown, ra != rb { return ra < rb }
            return a.offset < b.offset
        }.map(\.element)
    }

    private func persistOrderFromStack() {
        let stack = tasksStack
        var order: [String] = []
        var seen = Set<String>()
        for view in stack.arrangedSubviews {
            guard let orderable = view as? TaskbarOrderable else { continue }
            let key = orderable.orderKey
            if seen.insert(key).inserted {
                order.append(key)
            }
            // Write the bundleID right behind the window id so the slot survives a
            // relaunch (window ids are per-launch) and so a pinned icon that starts
            // running lands where its pinned placeholder sat.
            if let alias = orderable.orderAliasKey, seen.insert(alias).inserted {
                order.append(alias)
            }
        }

        // Keep pinned relative order in sync with the strip.
        let pinned = TaskbarSettings.shared.pinnedBundleIDs
        if !pinned.isEmpty {
            let pinnedSet = Set(pinned)
            var reorderedPinned = order.filter { pinnedSet.contains($0) }
            for id in pinned where !reorderedPinned.contains(id) {
                reorderedPinned.append(id)
            }
            if reorderedPinned != pinned {
                UserDefaults.standard.set(reorderedPinned, forKey: "pinnedBundleIDs")
            }
        }

        // Persist order; one notification refreshes every taskbar screen.
        // Pinned IDs are written directly so Start Menu picks them up next open.
        UserDefaults.standard.set(order, forKey: "taskbarOrder")
        NotificationCenter.default.post(name: .taskbarOrderChanged, object: nil)
    }

    private func performClick(on view: NSView) {
        if let task = view as? TaskButtonView {
            WindowPreviewController.shared.dismissAfterClick(on: task)
            task.onActivate?(task.windowInfo)
        } else if let pinned = view as? PinnedButtonView {
            pinned.onLaunch?(pinned.bundleID)
        }
    }

    private func moveIcon(_ view: NSView, in stack: NSStackView, toward event: NSEvent) {
        let point = stack.convert(event.locationInWindow, from: nil)
        // Overflowed buttons are hidden at the tail of the stack; dropping past the
        // last visible icon must not slot the dragged one in behind them.
        let arranged = stack.arrangedSubviews.filter { !$0.isHidden }
        guard let fromIndex = arranged.firstIndex(of: view) else { return }

        var toIndex = arranged.count - 1
        for (index, sibling) in arranged.enumerated() where sibling !== view {
            if point.x < sibling.frame.midX {
                toIndex = index > fromIndex ? index - 1 : index
                break
            }
        }
        toIndex = max(0, min(toIndex, arranged.count - 1))
        guard toIndex != fromIndex else { return }

        // Keep the view in the hierarchy — removeFromSuperview mid-drag
        // cancels mouse tracking and leaves the icon stuck grey.
        // Animate sibling slides so reordering doesn't snap.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1.0)
            context.allowsImplicitAnimation = true
            stack.removeArrangedSubview(view)
            stack.insertArrangedSubview(view, at: toIndex)
            stack.layoutSubtreeIfNeeded()
        }
        didReorderDuringDrag = true
    }

    private func beginDragMouseUpMonitor(for view: NSView) {
        endDragMouseUpMonitor()
        dragMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            self?.finishIconDrag(view, event: event)
            return event
        }
    }

    private func endDragMouseUpMonitor() {
        if let dragMouseUpMonitor {
            NSEvent.removeMonitor(dragMouseUpMonitor)
            self.dragMouseUpMonitor = nil
        }
    }

    private func finishIconDrag(_ view: NSView, event: NSEvent) {
        guard isDraggingIcon || dragStartLocation != nil else { return }
        endDragMouseUpMonitor()

        let wasDragging = isDraggingIcon
        let didReorder = didReorderDuringDrag
        isDraggingIcon = false
        draggingIcon = nil
        dragStartLocation = nil
        didReorderDuringDrag = false
        view.layer?.opacity = 1
        NSCursor.arrow.set()

        if wasDragging {
            if didReorder {
                persistOrderFromStack()
            }
            // persistOrderFromStack's notification has normally reloaded already.
            if needsReloadAfterDrag {
                reload()
            }
            // Drag (even without a reorder) must not open/activate the icon.
            return
        }
        performClick(on: view)
    }

    override func layout() {
        super.layout()
        // The first fit runs before the container has a width (it estimates from the
        // screen), and screens change size — refit once the real width differs.
        guard !isDraggingIcon, abs(tasksContainer.bounds.width - fittedWidth) > 0.5 else { return }
        fitButtons()
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking empty taskbar closes start menu / downloads pane
        if startMenu.isVisible {
            startMenu.hide()
            startOpen = false
            startButton.setHighlighted(false)
        }
        if DownloadsPanelController.shared.isVisible {
            DownloadsPanelController.shared.hide()
        }
        if TrashPanelController.shared.isVisible {
            TrashPanelController.shared.hide()
        }
        super.mouseDown(with: event)
    }
}

extension TaskbarContentView: TaskbarIconDragDelegate {
    func taskbarIconMouseDown(_ view: NSView, event: NSEvent) {
        endDragMouseUpMonitor()
        isDraggingIcon = false
        draggingIcon = nil
        didReorderDuringDrag = false
        dragStartLocation = event.locationInWindow
        view.layer?.opacity = 1
        // Defer open/activate until mouseUp so a reorder drag doesn't launch
        // a closed pinned app (or front a window you were only rearranging).
    }

    func taskbarIconMouseDragged(_ view: NSView, event: NSEvent) {
        guard let start = dragStartLocation else { return }
        let dx = abs(event.locationInWindow.x - start.x)
        let dy = abs(event.locationInWindow.y - start.y)
        if !isDraggingIcon {
            guard dx >= dragThreshold || dy >= dragThreshold else { return }
            isDraggingIcon = true
            draggingIcon = view
            WindowPreviewController.shared.hide()
            view.layer?.opacity = 0.55
            NSCursor.closedHand.set()
            beginDragMouseUpMonitor(for: view)
        }
        moveIcon(view, in: tasksStack, toward: event)
    }

    func taskbarIconMouseUp(_ view: NSView, event: NSEvent) {
        finishIconDrag(view, event: event)
    }
}

/// Windows-style "»" at the end of a full strip, listing the buttons that didn't fit.
private final class TaskOverflowButtonView: NSView {
    struct Entry {
        let title: String
        let icon: NSImage?
        let isActive: Bool
        let perform: () -> Void
    }

    /// Asked at click time, so the menu reflects the strip as it is now.
    var entriesProvider: (() -> [Entry])?

    /// Shows the active-window accent here when the focused window is one of the
    /// hidden ones, so the bar never looks like nothing has focus.
    var containsActiveWindow = false {
        didSet { refreshAppearance() }
    }

    private let chevron = NSImageView()
    private let underline = NSView()
    private var tracking: NSTrackingArea?
    private var isHovered = false
    private var shownEntries: [Entry] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        toolTip = "More windows"

        chevron.image = NSImage(systemSymbolName: "chevron.right.2", accessibilityDescription: nil)
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        chevron.contentTintColor = .labelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)

        underline.wantsLayer = true
        underline.layer?.cornerRadius = 1
        underline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(underline)

        NSLayoutConstraint.activate([
            chevron.centerXAnchor.constraint(equalTo: centerXAnchor),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),

            underline.leadingAnchor.constraint(equalTo: leadingAnchor),
            underline.trailingAnchor.constraint(equalTo: trailingAnchor),
            underline.bottomAnchor.constraint(equalTo: bottomAnchor),
            underline.heightAnchor.constraint(equalToConstant: 4)
        ])
        refreshAppearance()
        TaskbarAppearance.addObserver(self, selector: #selector(refreshAppearance))
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func refreshAppearance() {
        underline.isHidden = !containsActiveWindow
        underline.layer?.backgroundColor = resolvedCGColor(.controlAccentColor)
        layer?.backgroundColor = isHovered
            ? NSColor.white.withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        showMenu(with: event)
    }

    private func showMenu(with event: NSEvent) {
        let entries = entriesProvider?() ?? []
        guard !entries.isEmpty else { return }
        shownEntries = entries

        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, entry) in entries.enumerated() {
            let title = entry.title.count > 60 ? String(entry.title.prefix(59)) + "…" : entry.title
            let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = entry.isActive ? .on : .off
            if let icon = entry.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            menu.addItem(item)
        }
        popUpTaskbarIconMenu(menu, with: event, in: self)
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard shownEntries.indices.contains(sender.tag) else { return }
        shownEntries[sender.tag].perform()
    }
}
