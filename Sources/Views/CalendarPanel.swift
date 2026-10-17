import AppKit

/// Borderless panels refuse key status by default, and the flyout has to be key
/// for Escape to reach its key monitor.
private final class CalendarKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Clock flyout — a Windows-style month calendar anchored above the clock.
///
/// Mirrors DownloadsPanelController's presentation (borderless floating panel,
/// click-outside/Escape to dismiss, taskbar held visible while open) so all three
/// tray flyouts behave identically.
@MainActor
final class CalendarPanelController {
    static let shared = CalendarPanelController()

    private var panel: NSPanel?
    private weak var anchor: NSView?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    /// Cmd-Tab, Mission Control or another app stealing focus closes the flyout.
    private lazy var focus = FlyoutFocus { [weak self] in
        self?.hide(restoringFocus: false)
    }

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
        hide(restoringFocus: true)
    }

    /// `restoringFocus` is false when the user dismissed the flyout by moving to
    /// another app, which then already has focus and must keep it.
    private func hide(restoringFocus: Bool) {
        let wasVisible = panel != nil
        removeMonitors()
        (panel?.contentView as? CalendarPanelView)?.stopClock()
        panel?.orderOut(nil)
        panel = nil
        (anchor as? TrayItemButtonView)?.isOpen = false
        (anchor as? ClockButtonView)?.isOpen = false
        anchor = nil
        if wasVisible {
            focus.end(restoringFocus: restoringFocus)
            TaskbarPanelController.shared.endKeepVisible()
        }
    }

    private func show(relativeTo view: NSView) {
        DownloadsPanelController.shared.hide()
        TrashPanelController.shared.hide()
        hide(restoringFocus: false)
        guard let window = view.window else { return }

        let content = CalendarPanelView()
        content.onRequestClose = { [weak self] in
            self?.hide()
        }
        let size = content.fittingSize
        let width = size.width
        let height = size.height

        let panel = CalendarKeyablePanel(
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
        // Same Spaces behaviour as the bar it hangs off, which stays out of
        // full-screen Spaces.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        // Dark like the taskbar regardless of the system theme.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = content

        // Flush to the right edge of the screen with a small gutter, not to the clock
        // button — the Show Desktop strip sits outboard of the clock, so anchoring to
        // the button leaves the panel visibly short of the bar's edge.
        let screenFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
        let rightEdge = (window.screen ?? NSScreen.main)?.frame.maxX ?? screenFrame.maxX
        let x = rightEdge - width - PanelMetrics.flyoutEdgeGutter
        let y = screenFrame.maxY + PanelMetrics.flyoutEdgeGutter
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)

        focus.begin()
        panel.makeKeyAndOrderFront(nil)
        AppLog.debug("calendar flyout shown", [
            "width": width,
            "height": height,
            "x": x,
            "y": y
        ])

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
        // A click in another app activates it; leave focus where the user put it.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide(restoringFocus: false)
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
    private let effect = NSVisualEffectView()
    private let tint = NSView()

    /// Autoupdating so a first-weekday or region change in System Settings applies
    /// without reopening the flyout.
    private let calendar = Calendar.autoupdatingCurrent
    /// First day of the month currently on screen; the arrows move this.
    private var displayedMonth: Date

    /// 6 rows always, so paging months never resizes the panel.
    private static let rowCount = 6
    private static let columnCount = 7

    static let panelWidth: CGFloat = 320
    /// Every element in the panel hangs off this one margin — the clock, the divider,
    /// the month label and the day grid all share the same left and right edge.
    private static let inset: CGFloat = 20
    private static var columnWidth: CGFloat { (panelWidth - inset * 2) / CGFloat(columnCount) }

    private var dayCells: [CalendarDayCell] = []
    private var weekdayLabels: [NSTextField] = []

    init() {
        displayedMonth = Calendar.current.date(
            from: Calendar.current.dateComponents([.year, .month], from: Date())
        ) ?? Date()
        super.init(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 0))
        // No explicit width/height constraint on self: this view becomes a window's
        // contentView, so AppKit owns its frame via the autoresizing bridge, and a
        // competing size constraint makes the first layout pass lay out wrong before
        // settling. The fixed column widths plus the inset constraints already imply
        // panelWidth, so `fittingSize` reports the intended size on its own.
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        addSubview(effect, positioned: .below, relativeTo: nil)

        tint.wantsLayer = true
        addSubview(tint, positioned: .above, relativeTo: effect)
        refreshBackground()
        TaskbarAppearance.addObserver(self, selector: #selector(refreshBackground))

        for background in [effect, tint] {
            background.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                background.leadingAnchor.constraint(equalTo: leadingAnchor),
                background.trailingAnchor.constraint(equalTo: trailingAnchor),
                background.topAnchor.constraint(equalTo: topAnchor),
                background.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        buildHeader()
        buildGrid()
        reloadGrid()
        tick()
        // Covers midnight (the "today" circle would otherwise sit on yesterday while
        // the flyout stays open) as well as locale, time zone and wake changes.
        NotificationCenter.default.addObserver(self, selector: #selector(clockChanged), name: TaskbarClock.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        clockTimer?.invalidate()
    }

    @objc private func refreshBackground() {
        // Same treatment as the taskbar: Windows' solid grey instead of vibrancy.
        let opaque = TaskbarAppearance.reduceTransparency
        effect.isHidden = opaque
        tint.layer?.backgroundColor = opaque
            ? TaskbarAppearance.opaqueBackground.cgColor
            : NSColor.black.withAlphaComponent(0.28).cgColor
    }

    @objc private func clockChanged() {
        reloadGrid()
        tick()
    }

    // MARK: - Live clock

    /// Driven only while the panel is on screen — a tray flyout that keeps a 1s
    /// timer alive after dismissal would tick forever behind the user's back.
    /// Aligned to whole seconds so the readout turns over with the system clock
    /// rather than up to a second late.
    func startClock() {
        stopClock()
        tick()
        let next = Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded(.down) + 1)
        let timer = Timer(fire: next, interval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
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
        timeLabel.stringValue = TaskbarClock.shared.longTime.string(from: now)
        dateLabel.stringValue = TaskbarClock.shared.fullDate.string(from: now)
    }

    // MARK: - Layout

    private func buildHeader() {
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 26, weight: .regular)
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

        let inset = Self.inset
        // The arrows are square hit targets around a small glyph, so their box has to
        // overhang the text margin for the glyph itself to land on it.
        let arrowSize: CGFloat = 28
        let glyphOverhang = (arrowSize - 16) / 2

        NSLayoutConstraint.activate([
            clockStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            clockStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            clockStack.topAnchor.constraint(equalTo: topAnchor, constant: 16),

            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            divider.topAnchor.constraint(equalTo: clockStack.bottomAnchor, constant: 14),
            divider.heightAnchor.constraint(equalToConstant: 1),

            monthLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            monthLabel.centerYAnchor.constraint(equalTo: prev.centerYAnchor),

            next.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(inset - glyphOverhang)),
            next.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 10),
            next.widthAnchor.constraint(equalToConstant: arrowSize),
            next.heightAnchor.constraint(equalToConstant: arrowSize),

            prev.trailingAnchor.constraint(equalTo: next.leadingAnchor),
            prev.centerYAnchor.constraint(equalTo: next.centerYAnchor),
            prev.widthAnchor.constraint(equalToConstant: arrowSize),
            prev.heightAnchor.constraint(equalToConstant: arrowSize)
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
        grid.rowSpacing = 0
        grid.columnSpacing = 0
        // Cells must fill their column, otherwise the weekday letters (intrinsically
        // narrow text fields) hug the leading edge while the day numbers below them
        // centre in a full-width cell, and the two rows visibly disagree.
        grid.xPlacement = .fill
        grid.yPlacement = .fill
        addSubview(grid)

        // Weekday header; reloadGrid fills in the letters.
        weekdayLabels = (0..<Self.columnCount).map { _ in
            let label = NSTextField(labelWithString: "")
            label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            return label
        }
        grid.addRow(with: weekdayLabels)

        for _ in 0..<Self.rowCount {
            let cells = (0..<Self.columnCount).map { _ -> CalendarDayCell in
                let cell = CalendarDayCell()
                dayCells.append(cell)
                return cell
            }
            grid.addRow(with: cells)
        }

        for column in 0..<Self.columnCount {
            grid.column(at: column).width = Self.columnWidth
        }
        for row in 0..<(Self.rowCount + 1) {
            grid.row(at: row).height = row == 0 ? 22 : Self.columnWidth
        }

        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            grid.topAnchor.constraint(equalTo: headerBottom ?? topAnchor, constant: 4),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset)
        ])
    }

    private func reloadGrid() {
        monthLabel.stringValue = TaskbarClock.shared.monthYear.string(from: displayedMonth)

        // Rotated to the locale's first weekday so the columns line up with the day
        // cells below.
        let symbols = calendar.veryShortWeekdaySymbols
        let offset = calendar.firstWeekday - 1
        for (column, label) in weekdayLabels.enumerated() {
            label.stringValue = symbols[(column + offset) % symbols.count]
        }

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
                cell.configure(date: nil, isToday: false, isCurrentMonth: false)
                continue
            }
            let inMonth = calendar.isDate(cellDate, equalTo: firstOfMonth, toGranularity: .month)
            cell.configure(
                date: cellDate,
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
    /// Fixed-size circle centred in the cell. Rounding the cell itself yields a
    /// stadium, since cells are as wide as a column but shorter than they are wide.
    private let marker = NSView()
    private static let markerDiameter: CGFloat = 28

    private var date: Date?
    private var isToday = false

    init() {
        super.init(frame: .zero)
        marker.wantsLayer = true
        marker.layer?.cornerRadius = Self.markerDiameter / 2
        marker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(marker)

        label.font = NSFont.systemFont(ofSize: 12)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityElement(false)
        addSubview(label)

        NSLayoutConstraint.activate([
            marker.centerXAnchor.constraint(equalTo: centerXAnchor),
            marker.centerYAnchor.constraint(equalTo: centerYAnchor),
            marker.widthAnchor.constraint(equalToConstant: Self.markerDiameter),
            marker.heightAnchor.constraint(equalToConstant: Self.markerDiameter),

            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        TaskbarAppearance.addObserver(self, selector: #selector(refreshMarker))
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(date: Date?, isToday: Bool, isCurrentMonth: Bool) {
        self.date = date
        self.isToday = isToday
        label.stringValue = date.map { "\(Calendar.autoupdatingCurrent.component(.day, from: $0))" } ?? ""
        if isToday {
            // White on the accent fill, like Windows' today highlight.
            label.textColor = .white
            label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        } else {
            label.textColor = isCurrentMonth ? .labelColor : .tertiaryLabelColor
            label.font = NSFont.systemFont(ofSize: 12)
        }
        refreshMarker()
    }

    @objc private func refreshMarker() {
        marker.layer?.backgroundColor = isToday
            ? resolvedCGColor(.controlAccentColor)
            : NSColor.clear.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshMarker()
    }

    // MARK: - Accessibility

    // Static text rather than a button: days have no action, and VoiceOver would
    // otherwise announce a control that does nothing when pressed.
    override func isAccessibilityElement() -> Bool { date != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? {
        date.map { TaskbarClock.shared.fullDate.string(from: $0) }
    }
    override func accessibilityValue() -> Any? { isToday ? "Today" : nil }
}
