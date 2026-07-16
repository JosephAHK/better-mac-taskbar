import AppKit
import ApplicationServices

final class TaskbarContentView: NSView {
    private let startButton = StartButtonView()
    private let tasksContainer = NSView()
    private let tray = TrayView()
    private let startMenu = StartMenuController()
    private var startOpen = false

    private weak var tasksStack: NSStackView?
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
        tray.onOpenSettings = {
            SettingsWindowController.shared.show()
        }

        NSLayoutConstraint.activate([
            startButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            startButton.topAnchor.constraint(equalTo: topAnchor),
            startButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            startButton.widthAnchor.constraint(equalTo: heightAnchor),

            tray.trailingAnchor.constraint(equalTo: trailingAnchor),
            tray.topAnchor.constraint(equalTo: topAnchor),
            tray.bottomAnchor.constraint(equalTo: bottomAnchor),
            tray.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),

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

        let height = bounds.height > 0 ? bounds.height : TaskbarSettings.shared.barHeight
        let buttonSize = height
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        tasksContainer.addSubview(stack)
        tasksStack = stack

        let center = TaskbarSettings.shared.centerIcons
        if center {
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: tasksContainer.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: tasksContainer.centerYAnchor),
                stack.heightAnchor.constraint(equalTo: tasksContainer.heightAnchor)
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
            case .pinned(let bundleID):
                let pinned = PinnedButtonView(bundleID: bundleID, size: buttonSize)
                pinned.dragDelegate = self
                pinned.onLaunch = { PinManager.launch(bundleID: $0) }
                pinned.onUnpin = { PinManager.togglePin(bundleID: $0) }
                pinned.onHide = { HideManager.toggleHidden(bundleID: $0) }
                stack.addArrangedSubview(pinned)
                pinned.widthAnchor.constraint(equalToConstant: buttonSize).isActive = true
                pinned.heightAnchor.constraint(equalToConstant: buttonSize).isActive = true
            case .window(let info):
                let button = TaskButtonView(windowInfo: info, size: buttonSize)
                button.dragDelegate = self
                button.onActivate = { info in
                    WindowManager.shared.activateOrMinimizeWindow(info)
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
                button.widthAnchor.constraint(equalToConstant: buttonSize).isActive = true
                button.heightAnchor.constraint(equalToConstant: buttonSize).isActive = true
            }
        }
    }

    /// When the icon set/order is unchanged, only refresh active underlines — no layout jump.
    private func applyInPlaceIfPossible(_ items: [DisplayItem]) -> Bool {
        guard let stack = tasksStack else { return false }
        let views = stack.arrangedSubviews
        guard views.count == items.count else { return false }
        for (view, item) in zip(views, items) {
            switch item {
            case .pinned(let bundleID):
                guard (view as? PinnedButtonView)?.bundleID == bundleID else { return false }
            case .window(let info):
                guard (view as? TaskButtonView)?.windowInfo.id == info.id else { return false }
            }
        }
        for (view, item) in zip(views, items) {
            if case .window(let info) = item, let button = view as? TaskButtonView {
                button.apply(info)
            }
        }
        return true
    }

    private enum DisplayItem {
        case pinned(String)
        case window(WindowInfo)

        var orderKey: String {
            switch self {
            case .pinned(let bundleID): return bundleID
            case .window(let info): return info.id
            }
        }
    }

    private static func orderedDisplayItems() -> [DisplayItem] {
        let windows = WindowManager.shared.windows
        let hidden = Set(TaskbarSettings.shared.hiddenBundleIDs)
        let runningBundleIDs = Set(windows.compactMap(\.bundleID))
        var items: [DisplayItem] = []
        for bundleID in TaskbarSettings.shared.pinnedBundleIDs
            where !runningBundleIDs.contains(bundleID) && !hidden.contains(bundleID) {
            items.append(.pinned(bundleID))
        }
        for info in windows {
            if let bid = info.bundleID, hidden.contains(bid) { continue }
            items.append(.window(info))
        }

        let order = TaskbarSettings.shared.taskbarOrder
        guard !order.isEmpty else { return items }

        var rank: [String: Int] = [:]
        for (index, key) in order.enumerated() where rank[key] == nil {
            rank[key] = index
        }

        return items.enumerated().sorted { a, b in
            let ra = rank[a.element.orderKey] ?? Int.max
            let rb = rank[b.element.orderKey] ?? Int.max
            if ra != rb { return ra < rb }
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
        stack.removeArrangedSubview(view)
        stack.insertArrangedSubview(view, at: toIndex)
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
        if VolumePanelController.shared.isVisible {
            VolumePanelController.shared.hide()
        }
        if WiFiPanelController.shared.isVisible {
            WiFiPanelController.shared.hide()
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
