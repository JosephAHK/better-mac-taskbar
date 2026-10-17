import AppKit

final class TrayView: NSView {
    var onShowDesktop: (() -> Void)?

    private let downloadsButton = DownloadsButtonView()
    private let trashButton = TrashButtonView()
    private let clockButton = ClockButtonView()
    private let showDesktop = ShowDesktopButtonView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        downloadsButton.translatesAutoresizingMaskIntoConstraints = false
        downloadsButton.onToggle = { [weak self] in
            guard let self else { return }
            DownloadsPanelController.shared.toggle(relativeTo: self.downloadsButton)
        }

        trashButton.translatesAutoresizingMaskIntoConstraints = false
        trashButton.onToggle = { [weak self] in
            guard let self else { return }
            TrashPanelController.shared.toggle(relativeTo: self.trashButton)
        }

        let downloadsDivider = makeDivider()

        clockButton.translatesAutoresizingMaskIntoConstraints = false
        clockButton.onToggle = { [weak self] in
            guard let self else { return }
            CalendarPanelController.shared.toggle(relativeTo: self.clockButton)
        }
        NSLayoutConstraint.activate([
            clockButton.heightAnchor.constraint(equalToConstant: TaskbarSettings.barHeight)
        ])

        showDesktop.onClick = { [weak self] in
            self?.onShowDesktop?()
        }
        showDesktop.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(downloadsButton)
        stack.addArrangedSubview(trashButton)
        stack.addArrangedSubview(downloadsDivider)
        stack.addArrangedSubview(clockButton)
        stack.addArrangedSubview(showDesktop)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Width is intrinsic now that these carry labels — pinning them square
            // would clip the text.
            downloadsButton.heightAnchor.constraint(equalTo: heightAnchor),
            trashButton.heightAnchor.constraint(equalTo: heightAnchor),

            showDesktop.widthAnchor.constraint(equalToConstant: 14),
            showDesktop.heightAnchor.constraint(equalTo: stack.heightAnchor)
        ])
    }

    private func makeDivider() -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.widthAnchor.constraint(equalToConstant: 11).isActive = true

        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            line.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            line.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 28)
        ])
        return wrap
    }
}

/// One clock source shared by every screen's tray clock and the calendar flyout.
///
/// Formats come from locale templates rather than fixed patterns, so the 12/24-hour
/// preference, field order and language follow System Settings. Formatters are
/// costly to build, so they are made once and rebuilt only when the locale or time
/// zone actually changes.
@MainActor
final class TaskbarClock {
    static let shared = TaskbarClock()

    /// Posted on every minute boundary, and whenever the shown time may have jumped
    /// or reformatted: wake, a manual clock change, time zone, locale, or midnight.
    static let didChange = Notification.Name("TaskbarClockDidChange")

    /// Tray clock: hours and minutes.
    private(set) var shortTime = DateFormatter()
    /// Tray clock's second line.
    private(set) var shortDate = DateFormatter()
    /// Calendar flyout's live readout.
    private(set) var longTime = DateFormatter()
    private(set) var fullDate = DateFormatter()
    private(set) var monthYear = DateFormatter()
    /// Spoken by VoiceOver for the tray clock.
    private(set) var dateAndTime = DateFormatter()

    private var minuteTimer: Timer?

    private init() {
        rebuildFormatters()
        scheduleNextMinute()

        // Block observers on the main queue: the clock and calendar-day
        // notifications are not guaranteed to arrive on the main thread.
        let names: [Notification.Name] = [
            .NSSystemTimeZoneDidChange,
            .NSSystemClockDidChange,
            .NSCalendarDayChanged,
            NSLocale.currentLocaleDidChangeNotification
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.timeChanged() }
            }
        }
        // Timers don't fire on schedule across sleep, so the minute is stale on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.timeChanged() }
        }
    }

    private func timeChanged() {
        rebuildFormatters()
        scheduleNextMinute()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func rebuildFormatters() {
        shortTime = Self.formatter(template: "jmm")
        longTime = Self.formatter(template: "jmmss")
        monthYear = Self.formatter(template: "yMMMM")
        shortDate = Self.formatter(dateStyle: .short, timeStyle: .none)
        fullDate = Self.formatter(dateStyle: .full, timeStyle: .none)
        dateAndTime = Self.formatter(dateStyle: .full, timeStyle: .short)
    }

    private static func formatter(template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private static func formatter(dateStyle: DateFormatter.Style, timeStyle: DateFormatter.Style) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter
    }

    /// The tray shows no seconds, so it repaints once per minute, re-aimed at the
    /// next boundary each time rather than drifting on a repeating interval. Every
    /// time zone is offset by whole minutes, so reference-date minutes line up with
    /// local ones.
    private func scheduleNextMinute() {
        minuteTimer?.invalidate()
        let minutes = (Date().timeIntervalSinceReferenceDate / 60).rounded(.down)
        let next = Date(timeIntervalSinceReferenceDate: (minutes + 1) * 60)
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scheduleNextMinute()
                NotificationCenter.default.post(name: Self.didChange, object: nil)
            }
        }
        // .common keeps the clock moving while a menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }
}

/// Taskbar clock — two stacked lines, opens the calendar flyout on click.
///
/// A custom view rather than an NSButton so it can carry the same hover and
/// open-state tint as the other tray flyout buttons.
final class ClockButtonView: NSView {
    var onToggle: (() -> Void)?

    var isOpen = false {
        didSet { refreshAppearance() }
    }

    private let timeLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        toolTip = "Click for calendar"

        // Monospaced digits keep the bar from shifting as the minutes tick over.
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        timeLabel.textColor = .labelColor
        timeLabel.alignment = .right
        dateLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        dateLabel.textColor = .labelColor
        dateLabel.alignment = .right

        let clockStack = NSStackView(views: [timeLabel, dateLabel])
        clockStack.orientation = .vertical
        clockStack.spacing = 0
        clockStack.alignment = .trailing
        clockStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clockStack)

        NSLayoutConstraint.activate([
            clockStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            clockStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            clockStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        ])

        for label in [timeLabel, dateLabel] {
            label.setAccessibilityElement(false)
        }
        update()
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: TaskbarClock.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func update() {
        let now = Date()
        timeLabel.stringValue = TaskbarClock.shared.shortTime.string(from: now)
        dateLabel.stringValue = TaskbarClock.shared.shortDate.string(from: now)
    }

    private func refreshAppearance() {
        if isOpen {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        } else if isHovered {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking!)
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
        onToggle?()
    }

    /// Right-click still reaches Date & Time settings, which the left click used to do.
    override func rightMouseDown(with event: NSEvent) {
        popUpTaskbarIconMenu(makeContextMenu(), with: event, in: self)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Date & Time Settings…", action: #selector(openDateTime), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func openDateTime() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Date-Time-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { TaskbarClock.shared.dateAndTime.string(from: Date()) }
    override func accessibilityHelp() -> String? { "Shows the calendar" }

    override func accessibilityPerformPress() -> Bool {
        onToggle?()
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        popUpTaskbarIconMenu(makeContextMenu(), with: nil, in: self)
        return true
    }
}

/// Far-right Show Desktop strip — full bar height so clicks register on the nonactivating panel.
private final class ShowDesktopButtonView: NSView {
    var onClick: (() -> Void)?
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        toolTip = "Show desktop"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Show desktop" }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
