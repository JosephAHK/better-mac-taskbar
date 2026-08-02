import AppKit
import ApplicationServices

final class TaskbarContentView: NSView {
    private let startButton = StartButtonView()
    private let tasksContainer = NSView()
    private let tray = TrayView()
    private let startMenu = StartMenuController()
    private var startOpen = false

    private weak var tasksStack: NSStackView?
    private var buttonWidthConstraints: [NSLayoutConstraint] = []
    private var builtStyle: TaskbarButtonStyle = TaskbarSettings.shared.buttonStyle
    private weak var draggingIcon: NSView?
    private var isDraggingIcon = false
    private var dragStartLocation: NSPoint?
    private var didReorderDuringDrag = false
    private var dragMouseUpMonitor: Any?
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
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        endDragMouseUpMonitor()
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

        reload()
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
        if isDraggingIcon { return }

        let items = Self.orderedDisplayItems()
        if applyInPlaceIfPossible(items) {
            return
        }

        tasksContainer.subviews.forEach { $0.removeFromSuperview() }
        buttonWidthConstraints.removeAll()

        let height = bounds.height > 0 ? bounds.height : TaskbarSettings.shared.barHeight
        let style = TaskbarSettings.shared.buttonStyle
        builtStyle = style
        let buttonWidth = buttonWidth(for: items.count, style: style, height: height)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        tasksContainer.addSubview(stack)
        tasksStack = stack

        let center = TaskbarSettings.shared.centerIcons
        if center {
            // Center on the whole screen width (like Windows 11), not just the leftover
            // space between the Start button and tray — those two are rarely symmetric,
            // so centering within tasksContainer alone visibly drifts off true center.
            // Lower-priority centerX yields to the required containment constraints
            // below once there are enough icons to collide with Start/tray.
            let centerX = stack.centerXAnchor.constraint(equalTo: centerXAnchor)
            centerX.priority = .defaultHigh
            NSLayoutConstraint.activate([
                centerX,
                stack.centerYAnchor.constraint(equalTo: tasksContainer.centerYAnchor),
                stack.heightAnchor.constraint(equalTo: tasksContainer.heightAnchor),
                stack.leadingAnchor.constraint(greaterThanOrEqualTo: tasksContainer.leadingAnchor, constant: 4),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: tasksContainer.trailingAnchor, constant: -4)
            ])
        } else {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: tasksContainer.leadingAnchor, constant: 4),
                stack.centerYAnchor.constraint(equalTo: tasksContainer.centerYAnchor),
                stack.heightAnchor.constraint(equalTo: tasksContainer.heightAnchor)
            ])
        }

        for item in items {
            switch item {
            case .pinned(let bundleID), .launching(let bundleID):
                let pinned = PinnedButtonView(bundleID: bundleID, height: height, width: buttonWidth, style: style)
                pinned.dragDelegate = self
                pinned.setLaunching(LaunchTracker.shared.isLaunching(bundleID))
                pinned.onLaunch = { PinManager.launch(bundleID: $0) }
                pinned.onUnpin = { PinManager.togglePin(bundleID: $0) }
                pinned.onHide = { HideManager.toggleHidden(bundleID: $0) }
                stack.addArrangedSubview(pinned)
                let width = pinned.widthAnchor.constraint(equalToConstant: buttonWidth)
                width.isActive = true
                buttonWidthConstraints.append(width)
                pinned.heightAnchor.constraint(equalToConstant: height).isActive = true
            case .window(let info):
                let button = TaskButtonView(windowInfo: info, height: height, width: buttonWidth, style: style)
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
                stack.addArrangedSubview(button)
                let width = button.widthAnchor.constraint(equalToConstant: buttonWidth)
                width.isActive = true
                buttonWidthConstraints.append(width)
                button.heightAnchor.constraint(equalToConstant: height).isActive = true
            }
        }
    }

    /// Compact buttons are square. Labeled buttons take the full title width until
    /// the strip would overflow the space between Start and the tray, then shrink
    /// evenly; once they'd be too narrow to read they fall back to squares.
    private func buttonWidth(for count: Int, style: TaskbarButtonStyle, height: CGFloat) -> CGFloat {
        guard style.showsTitle, count > 0 else { return height }
        let available = availableTaskWidth()
        guard available > 0 else { return TaskbarButtonStyle.maxLabeledWidth }
        let fitted = available / CGFloat(count)
        if fitted < TaskbarButtonStyle.minLabeledWidth {
            // No room for readable titles — behave like compact so icons still fit.
            return height
        }
        return min(fitted, TaskbarButtonStyle.maxLabeledWidth)
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

    /// When the icon set/order is unchanged, only refresh active underlines — no layout jump.
    private func applyInPlaceIfPossible(_ items: [DisplayItem]) -> Bool {
        guard let stack = tasksStack else { return false }
        guard builtStyle == TaskbarSettings.shared.buttonStyle else { return false }
        let views = stack.arrangedSubviews
        guard views.count == items.count else { return false }
        for (view, item) in zip(views, items) {
            switch item {
            case .pinned(let bundleID), .launching(let bundleID):
                guard (view as? PinnedButtonView)?.bundleID == bundleID else { return false }
            case .window(let info):
                guard (view as? TaskButtonView)?.windowInfo.id == info.id else { return false }
            }
        }
        for (view, item) in zip(views, items) {
            switch item {
            case .window(let info):
                (view as? TaskButtonView)?.apply(info)
            case .pinned(let bundleID), .launching(let bundleID):
                (view as? PinnedButtonView)?.setLaunching(LaunchTracker.shared.isLaunching(bundleID))
            }
        }
        return true
    }

    private enum DisplayItem {
        case pinned(String)
        /// Unpinned app mid-launch — a placeholder slot that disappears once its
        /// first window shows up (or the launch times out).
        case launching(String)
        case window(WindowInfo)

        var orderKey: String {
            switch self {
            case .pinned(let bundleID), .launching(let bundleID): return bundleID
            case .window(let info): return info.id
            }
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
        guard let stack = tasksStack else { return }
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
            task.onActivate?(task.windowInfo)
        } else if let pinned = view as? PinnedButtonView {
            pinned.onLaunch?(pinned.bundleID)
        }
    }

    private func moveIcon(_ view: NSView, in stack: NSStackView, toward event: NSEvent) {
        let point = stack.convert(event.locationInWindow, from: nil)
        let arranged = stack.arrangedSubviews
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
        }
        // Click already fired on mouseDown — don't activate again on mouseUp.
    }

    override func layout() {
        super.layout()
        // Rebuild when height known on first layout
        if tasksContainer.subviews.isEmpty {
            reload()
            return
        }
        // The first build may have estimated the available width (container not laid
        // out yet), and the screen can change size — resize labeled buttons to fit.
        refreshButtonWidths()
    }

    private func refreshButtonWidths() {
        guard !buttonWidthConstraints.isEmpty, !isDraggingIcon else { return }
        let height = bounds.height > 0 ? bounds.height : TaskbarSettings.shared.barHeight
        let target = buttonWidth(for: buttonWidthConstraints.count, style: builtStyle, height: height)
        guard let first = buttonWidthConstraints.first, abs(first.constant - target) > 0.5 else { return }
        for constraint in buttonWidthConstraints {
            constraint.constant = target
        }
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
        // Fire on press (Win10-style) — don't wait for mouseUp.
        performClick(on: view)
    }

    func taskbarIconMouseDragged(_ view: NSView, event: NSEvent) {
        guard let start = dragStartLocation else { return }
        let dx = abs(event.locationInWindow.x - start.x)
        let dy = abs(event.locationInWindow.y - start.y)
        if !isDraggingIcon {
            guard dx >= dragThreshold || dy >= dragThreshold else { return }
            isDraggingIcon = true
            draggingIcon = view
            view.layer?.opacity = 0.55
            NSCursor.closedHand.set()
            beginDragMouseUpMonitor(for: view)
        }
        guard let stack = tasksStack else { return }
        moveIcon(view, in: stack, toward: event)
    }

    func taskbarIconMouseUp(_ view: NSView, event: NSEvent) {
        finishIconDrag(view, event: event)
    }
}
