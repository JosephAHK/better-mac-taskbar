import AppKit

/// Clock flyout — a Windows-style month calendar anchored above the clock.
///
/// Mirrors DownloadsPanelController's presentation (borderless floating panel,
/// click-outside/Escape to dismiss, taskbar held visible while open) so all three
/// tray flyouts behave identically.
final class CalendarPanelController {
    static let shared = CalendarPanelController()

    private var panel: NSPanel?
    private weak var anchor: NSView?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    var isVisible: Bool { panel?.isVisible == true }

    private init() {}

    func toggle(relativeTo view: NSView) {
        if isVisible, anchor === view {
            hide()
        } else {
            show(relativeTo: view)
        }
    }

    func hide() {
        let wasVisible = panel != nil
        removeMonitors()
        (panel?.contentView as? CalendarPanelView)?.stopClock()
        panel?.orderOut(nil)
        panel = nil
        (anchor as? TrayItemButtonView)?.isOpen = false
        (anchor as? ClockButtonView)?.isOpen = false
        anchor = nil
        if wasVisible {
            TaskbarPanelController.shared.endKeepVisible()
        }
    }

    private func show(relativeTo view: NSView) {
        DownloadsPanelController.shared.hide()
        TrashPanelController.shared.hide()
        hide()
        guard let window = view.window else { return }

        let width: CGFloat = 320
        let height: CGFloat = 360
        let content = CalendarPanelView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.onRequestClose = { [weak self] in
            self?.hide()
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.worksWhenModal = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = content

        // Right-align to the anchor, clamped to the screen — the clock sits at the
        // far right of the bar, so an unclamped panel would hang off the edge.
        let screenFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
        let x = min(max(screenFrame.maxX - width, screenFrame.minX), (window.screen?.visibleFrame.maxX ?? screenFrame.maxX) - width)
        let y = screenFrame.maxY + 2
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)

        panel.orderFront(nil)

        self.panel = panel
        self.anchor = view
        (view as? TrayItemButtonView)?.isOpen = true
        (view as? ClockButtonView)?.isOpen = true
        content.startClock()
        installMonitors()
        TaskbarPanelController.shared.beginKeepVisible()
    }

    private func installMonitors() {
        removeMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if self.isVisible, event.keyCode == 53 { // Escape
                    self.hide()
                    return nil
                }
                return event
            }
            self.handleMouseDown(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }

    private func removeMonitors() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard let panel else { return }
        let location = NSEvent.mouseLocation
        if panel.frame.contains(location) { return }
        // Clicks on the clock itself are the toggle — let it close via toggle(),
        // otherwise the button would close and immediately reopen the panel.
        if let anchor, let window = anchor.window {
            let anchorScreen = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            if anchorScreen.contains(location) { return }
        }
        hide()
    }
}

/// Month grid plus a live clock readout.
final class CalendarPanelView: NSView {
    var onRequestClose: (() -> Void)?

    private let timeLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let monthLabel = NSTextField(labelWithString: "")
    private let grid = NSGridView()
    private var clockTimer: Timer?

    private let calendar = Calendar.current
    /// First day of the month currently on screen; the arrows move this.
    private var displayedMonth: Date

    /// 6 rows always, so paging months never resizes the panel.
    private static let rowCount = 6
    private static let columnCount = 7

    private var dayCells: [CalendarDayCell] = []

    override init(frame frameRect: NSRect) {
        displayedMonth = Calendar.current.date(
            from: Calendar.current.dateComponents([.year, .month], from: Date())
        ) ?? Date()
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        let effect = NSVisualEffectView(frame: bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        addSubview(effect, positioned: .below, relativeTo: nil)

        let tint = NSView(frame: bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        addSubview(tint, positioned: .above, relativeTo: effect)

        buildHeader()
        buildGrid()
        reloadGrid()
        tick()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        clockTimer?.invalidate()
    }

    // MARK: - Live clock

    /// Driven only while the panel is on screen — a tray flyout that keeps a 1s
    /// timer alive after dismissal would tick forever behind the user's back.
    func startClock() {
        stopClock()
        tick()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    private func tick() {
        let now = Date()
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm:ss a"
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "EEEE, MMMM d, yyyy"
        timeLabel.stringValue = timeFmt.string(from: now)
        dateLabel.stringValue = dateFmt.string(from: now)
    }

    // MARK: - Layout

    private func buildHeader() {
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 30, weight: .light)
        timeLabel.textColor = .labelColor
        dateLabel.font = NSFont.systemFont(ofSize: 12)
        dateLabel.textColor = .secondaryLabelColor

        let clockStack = NSStackView(views: [timeLabel, dateLabel])
        clockStack.orientation = .vertical
        clockStack.spacing = 1
        clockStack.alignment = .leading
        clockStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clockStack)

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        monthLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        monthLabel.textColor = .labelColor
        monthLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(monthLabel)

        let prev = makeArrow(symbol: "chevron.left", tip: "Previous month", action: #selector(goToPreviousMonth))
        let next = makeArrow(symbol: "chevron.right", tip: "Next month", action: #selector(goToNextMonth))
        addSubview(prev)
        addSubview(next)

        NSLayoutConstraint.activate([
            clockStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            clockStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            clockStack.topAnchor.constraint(equalTo: topAnchor, constant: 14),

            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            divider.topAnchor.constraint(equalTo: clockStack.bottomAnchor, constant: 12),
            divider.heightAnchor.constraint(equalToConstant: 1),

            monthLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            monthLabel.centerYAnchor.constraint(equalTo: prev.centerYAnchor),

            next.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            next.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 8),
            next.widthAnchor.constraint(equalToConstant: 26),
            next.heightAnchor.constraint(equalToConstant: 24),

            prev.trailingAnchor.constraint(equalTo: next.leadingAnchor, constant: -2),
            prev.centerYAnchor.constraint(equalTo: next.centerYAnchor),
            prev.widthAnchor.constraint(equalToConstant: 26),
            prev.heightAnchor.constraint(equalToConstant: 24)
        ])

        headerBottom = next.bottomAnchor
    }

    private var headerBottom: NSLayoutYAxisAnchor?

    private func makeArrow(symbol: String, tip: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = .labelColor
        button.toolTip = tip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func buildGrid() {
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 2
        grid.columnSpacing = 2
        addSubview(grid)

        // Weekday header, rotated to the locale's first weekday so the columns line
        // up with the day cells below.
        let symbols = calendar.veryShortWeekdaySymbols
        let offset = calendar.firstWeekday - 1
        let ordered = (0..<Self.columnCount).map { symbols[($0 + offset) % symbols.count] }
        let headerViews: [NSView] = ordered.map { symbol in
            let label = NSTextField(labelWithString: symbol)
            label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            return label
        }
        grid.addRow(with: headerViews)

        for _ in 0..<Self.rowCount {
            let cells = (0..<Self.columnCount).map { _ -> CalendarDayCell in
                let cell = CalendarDayCell()
                dayCells.append(cell)
                return cell
            }
            grid.addRow(with: cells)
        }

        for column in 0..<Self.columnCount {
            grid.column(at: column).width = 38
        }
        for row in 0..<(Self.rowCount + 1) {
            grid.row(at: row).height = row == 0 ? 16 : 34
        }

        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: centerXAnchor),
            grid.topAnchor.constraint(equalTo: headerBottom ?? topAnchor, constant: 6)
        ])
    }

    private func reloadGrid() {
        let monthFmt = DateFormatter()
        monthFmt.dateFormat = "MMMM yyyy"
        monthLabel.stringValue = monthFmt.string(from: displayedMonth)

        guard let firstOfMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: displayedMonth)
        ) else { return }

        // How many trailing days of the previous month pad the first row.
        let weekdayOfFirst = calendar.component(.weekday, from: firstOfMonth)
        let leadingBlanks = (weekdayOfFirst - calendar.firstWeekday + 7) % 7
        let today = Date()

        for (index, cell) in dayCells.enumerated() {
            guard let cellDate = calendar.date(
                byAdding: .day,
                value: index - leadingBlanks,
                to: firstOfMonth
            ) else {
                cell.configure(day: "", isToday: false, isCurrentMonth: false)
                continue
            }
            let day = calendar.component(.day, from: cellDate)
            let inMonth = calendar.isDate(cellDate, equalTo: firstOfMonth, toGranularity: .month)
            cell.configure(
                day: "\(day)",
                isToday: calendar.isDate(cellDate, inSameDayAs: today),
                isCurrentMonth: inMonth
            )
        }
    }

    // MARK: - Paging

    @objc private func goToPreviousMonth() {
        shiftMonth(by: -1)
    }

    @objc private func goToNextMonth() {
        shiftMonth(by: 1)
    }

    private func shiftMonth(by months: Int) {
        guard let shifted = calendar.date(byAdding: .month, value: months, to: displayedMonth) else { return }
        displayedMonth = shifted
        reloadGrid()
    }
}

/// One day in the month grid. A plain view rather than an NSButton so the "today"
/// circle can be drawn without fighting button bezel styling.
private final class CalendarDayCell: NSView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        label.font = NSFont.systemFont(ofSize: 12)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    func configure(day: String, isToday: Bool, isCurrentMonth: Bool) {
        label.stringValue = day
        if isToday {
            layer?.backgroundColor = NSColor(calibratedRed: 0, green: 0.47, blue: 0.84, alpha: 1).cgColor
            label.textColor = .white
            label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            label.textColor = isCurrentMonth ? .labelColor : .tertiaryLabelColor
            label.font = NSFont.systemFont(ofSize: 12)
        }
    }
}
