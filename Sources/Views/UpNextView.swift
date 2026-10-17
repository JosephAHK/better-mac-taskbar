import AppKit

/// "Up Next" list at the top of the calendar flyout, like the macOS Calendar
/// widget: events grouped under day headers, each with its calendar's colour bar.
///
/// Renders `UpcomingEvents`' cached list straight away and re-renders whenever it
/// publishes. Collapses to zero height (padding and divider included) while
/// there's nothing to say yet, i.e. during the first access prompt.
final class UpNextView: NSView {
    /// A row was clicked; the owner closes the flyout and opens `url`.
    var onOpen: ((URL) -> Void)?
    /// The row set changed, so the flyout must re-fit its height.
    var onHeightChange: (() -> Void)?

    private let stack = NSStackView()
    private static let maxEvents = 6
    /// Rows' highlight overhangs the flyout's text margin by this much each side,
    /// so their text still lines up with the clock and month grid.
    static let rowPadding: CGFloat = 6

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsetsZero
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        // An empty stack has no intrinsic height; pin it to zero rather than leave
        // the flyout's fittingSize ambiguous. The rows' fixed heights outrank this.
        let collapsed = heightAnchor.constraint(equalToConstant: 0)
        collapsed.priority = .defaultLow
        collapsed.isActive = true
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(eventsChanged), name: UpcomingEvents.didChange, object: nil)
        // Minute tick re-renders the cache immediately, so an event that just ended
        // or started doesn't wait for the background fetch.
        NotificationCenter.default.addObserver(self, selector: #selector(eventsChanged), name: TaskbarClock.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func eventsChanged() {
        reload()
        onHeightChange?()
    }

    private func reload() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let source = UpcomingEvents.shared
        switch source.access {
        case .notDetermined:
            return
        case .denied:
            add(spacer(8))
            add(UpNextRow(message: "Allow Calendar access…", clickable: true) { [weak self] in
                guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
                self?.onOpen?(url)
            })
        case .granted:
            add(spacer(8))
            let now = Date()
            let visible = source.events.filter { $0.end > now }.prefix(Self.maxEvents)
            if visible.isEmpty {
                add(UpNextRow(message: "No upcoming events", clickable: false, action: nil))
            } else {
                addEvents(Array(visible), now: now)
            }
        }
        add(spacer(10))
        add(divider())
    }

    private func addEvents(_ events: [UpcomingEvent], now: Date) {
        let calendar = Calendar.autoupdatingCurrent
        // Built per render (a few times a minute at most while open) so a locale or
        // time zone change applies on the next tick without extra plumbing.
        let relative = DateFormatter()
        relative.locale = .autoupdatingCurrent
        relative.timeZone = .autoupdatingCurrent
        relative.dateStyle = .medium
        relative.timeStyle = .none
        relative.doesRelativeDateFormatting = true
        let weekday = DateFormatter()
        weekday.locale = .autoupdatingCurrent
        weekday.timeZone = .autoupdatingCurrent
        weekday.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        let range = DateIntervalFormatter()
        range.locale = .autoupdatingCurrent
        range.timeZone = .autoupdatingCurrent
        range.dateStyle = .none
        range.timeStyle = .short

        var currentDay: Date?
        for event in events {
            // An event already in progress sits under today, not its start day.
            let day = calendar.startOfDay(for: max(event.start, now))
            if day != currentDay {
                currentDay = day
                let isNear = calendar.isDateInToday(day) || calendar.isDateInTomorrow(day)
                let header = (isNear ? relative : weekday).string(from: day)
                if stack.arrangedSubviews.count > 1 { add(spacer(4)) }
                add(UpNextDayHeader(text: header))
            }
            let time = event.isAllDay ? "All-day" : range.string(from: event.start, to: event.end)
            let isNow = !event.isAllDay && event.start <= now && now < event.end
            let row = UpNextRow(event: event, time: time, isNow: isNow) { [weak self] in
                guard let url = event.url else { return }
                self?.onOpen?(url)
            }
            add(row)
        }
    }

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    /// Same hairline as the one under the clock, held to the text margin.
    private func divider() -> NSView {
        let wrap = spacer(1)
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: Self.rowPadding),
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -Self.rowPadding),
            line.topAnchor.constraint(equalTo: wrap.topAnchor),
            line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor)
        ])
        return wrap
    }
}

private final class UpNextDayHeader: NSView {
    init(text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: UpNextView.rowPadding),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -UpNextView.rowPadding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// One event (colour bar, title, time) or a one-line message. A plain view with
/// its own hover tint rather than an NSButton, like the flyouts' other rows.
private final class UpNextRow: NSView {
    private let action: (() -> Void)?
    private let isNow: Bool
    private var isHovered = false
    private var tracking: NSTrackingArea?

    init(event: UpcomingEvent, time: String, isNow: Bool, action: @escaping () -> Void) {
        self.action = action
        self.isNow = isNow
        super.init(frame: .zero)
        setUp()

        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1.5
        bar.layer?.backgroundColor = event.color.cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)

        let title = NSTextField(labelWithString: event.title)
        title.font = NSFont.systemFont(ofSize: 12)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        // Truncate the title, never widen the flyout or squeeze the time.
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        let timeLabel = NSTextField(labelWithString: time)
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.alignment = .right
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(timeLabel)

        let padding = UpNextView.rowPadding
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.widthAnchor.constraint(equalToConstant: 3),
            bar.heightAnchor.constraint(equalToConstant: 14),

            title.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -8),

            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        toolTip = event.title
        refreshBackground()
    }

    init(message: String, clickable: Bool, action: (() -> Void)?) {
        self.action = clickable ? action : nil
        self.isNow = false
        super.init(frame: .zero)
        setUp()

        let label = NSTextField(labelWithString: message)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = clickable ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: UpNextView.rowPadding),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -UpNextView.rowPadding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 4
    }

    private func refreshBackground() {
        let alpha: CGFloat = isHovered && action != nil ? 0.14 : (isNow ? 0.08 : 0)
        layer?.backgroundColor = resolvedCGColor(NSColor.white.withAlphaComponent(alpha))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        guard action != nil else { return }
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
        refreshBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshBackground()
    }

    override func mouseDown(with event: NSEvent) {
        action?()
    }
}
