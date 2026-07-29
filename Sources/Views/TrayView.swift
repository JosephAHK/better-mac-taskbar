import AppKit

final class TrayView: NSView {
    var onShowDesktop: (() -> Void)?

    private let downloadsButton = DownloadsButtonView()
    private let trashButton = TrashButtonView()
    private let clockButton = NSButton()
    private let timeLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
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
            AppLog.info("tray click", ["target": "downloads"])
            DownloadsPanelController.shared.toggle(relativeTo: self.downloadsButton)
        }

        trashButton.translatesAutoresizingMaskIntoConstraints = false
        trashButton.onToggle = { [weak self] in
            guard let self else { return }
            AppLog.info("tray click", ["target": "trash"])
            TrashPanelController.shared.toggle(relativeTo: self.trashButton)
        }

        let downloadsDivider = makeDivider()

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

        clockButton.title = ""
        clockButton.bezelStyle = .inline
        clockButton.isBordered = false
        clockButton.target = self
        clockButton.action = #selector(openDateTime)
        clockButton.addSubview(clockStack)
        clockButton.translatesAutoresizingMaskIntoConstraints = false
        clockStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            clockButton.heightAnchor.constraint(equalToConstant: TaskbarSettings.barHeight),
            clockStack.centerYAnchor.constraint(equalTo: clockButton.centerYAnchor),
            clockStack.trailingAnchor.constraint(equalTo: clockButton.trailingAnchor, constant: -10),
            clockStack.leadingAnchor.constraint(equalTo: clockButton.leadingAnchor, constant: 10)
        ])

        showDesktop.onClick = { [weak self] in
            AppLog.info("tray click", ["target": "showDesktop"])
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

            downloadsButton.widthAnchor.constraint(equalTo: heightAnchor),
            downloadsButton.heightAnchor.constraint(equalTo: heightAnchor),

            trashButton.widthAnchor.constraint(equalTo: heightAnchor),
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
        let now = Date()
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "M/d/yyyy"
        timeLabel.stringValue = timeFmt.string(from: now)
        dateLabel.stringValue = dateFmt.string(from: now)
    }

    @objc private func openDateTime() {
        AppLog.info("tray click", ["target": "clock"])
        if let url = URL(string: "x-apple.systempreferences:com.apple.Date-Time-Settings.extension") {
            let opened = NSWorkspace.shared.open(url)
            if !opened {
                AppLog.warn("failed to open Date & Time settings")
            }
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
