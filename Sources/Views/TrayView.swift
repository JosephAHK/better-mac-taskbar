import AppKit

final class TrayView: NSView {
    var onShowDesktop: (() -> Void)?

    private let downloadsButton = DownloadsButtonView()
    private let trashButton = TrashButtonView()
    private let clockButton = ClockButtonView()
    private let showDesktop = ShowDesktopButtonView()
    private var clockTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
        tick()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let clockTimer {
            RunLoop.main.add(clockTimer, forMode: .common)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        clockTimer?.invalidate()
    }

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

    private func tick() {
        clockButton.update(with: Date())
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

    /// Held as instance state: DateFormatter construction is not cheap and this
    /// formats twice a second, every second, for the life of the process.
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        return formatter
    }()

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d/yyyy"
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        toolTip = "Click for calendar"

        // Monospaced digits keep the bar from shifting as the seconds tick over.
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
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(with date: Date) {
        timeLabel.stringValue = timeFormatter.string(from: date)
        dateLabel.stringValue = dateFormatter.string(from: date)
    }

    private func refreshAppearance() {
        if isOpen {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
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
        if !isOpen {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        refreshAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }

    /// Right-click still reaches Date & Time settings, which the left click used to do.
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Date & Time Settings…", action: #selector(openDateTime), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func openDateTime() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Date-Time-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
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
}
