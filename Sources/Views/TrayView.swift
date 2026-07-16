import AppKit

final class TrayView: NSView {
    var onShowDesktop: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let downloadsButton = DownloadsButtonView()
    private let wifiButton = NSButton()
    private let volumeButton = NSButton()
    private let clockButton = NSButton()
    private let timeLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let showDesktop = ShowDesktopButtonView()
    private let actionCenter = NSButton()
    private var clockTimer: Timer?
    private var volumeIconTimer: Timer?

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
        volumeIconTimer?.invalidate()
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

        let downloadsDivider = makeDivider()

        let chevron = makeTrayIconButton(systemName: "chevron.up", toolTip: "Hidden icons")

        configureTrayIconButton(wifiButton, systemName: "wifi", toolTip: "Network")
        wifiButton.target = self
        wifiButton.action = #selector(toggleWiFiMenu)

        configureTrayIconButton(volumeButton, systemName: VolumeService.speakerSymbolName(), toolTip: "Volume")
        volumeButton.target = self
        volumeButton.action = #selector(toggleVolumeSlider)

        volumeIconTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshVolumeIcon()
        }
        if let volumeIconTimer {
            RunLoop.main.add(volumeIconTimer, forMode: .common)
        }

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
            clockButton.widthAnchor.constraint(equalToConstant: 90),
            clockButton.heightAnchor.constraint(equalToConstant: TaskbarSettings.barHeight),
            clockStack.centerYAnchor.constraint(equalTo: clockButton.centerYAnchor),
            clockStack.trailingAnchor.constraint(equalTo: clockButton.trailingAnchor, constant: -8),
            clockStack.leadingAnchor.constraint(equalTo: clockButton.leadingAnchor, constant: 4)
        ])

        actionCenter.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: "Action Center")
        actionCenter.bezelStyle = .inline
        actionCenter.isBordered = false
        actionCenter.target = self
        actionCenter.action = #selector(openSettings)
        actionCenter.toolTip = "Settings"
        actionCenter.translatesAutoresizingMaskIntoConstraints = false
        actionCenter.widthAnchor.constraint(equalToConstant: 40).isActive = true

        showDesktop.onClick = { [weak self] in
            self?.onShowDesktop?()
        }
        showDesktop.translatesAutoresizingMaskIntoConstraints = false

        let desktopDivider = makeDivider()

        stack.addArrangedSubview(downloadsButton)
        stack.addArrangedSubview(downloadsDivider)
        stack.addArrangedSubview(chevron)
        stack.addArrangedSubview(wifiButton)
        stack.addArrangedSubview(volumeButton)
        stack.addArrangedSubview(clockButton)
        stack.addArrangedSubview(actionCenter)
        stack.addArrangedSubview(desktopDivider)
        stack.addArrangedSubview(showDesktop)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),

            downloadsButton.widthAnchor.constraint(equalTo: heightAnchor),
            downloadsButton.heightAnchor.constraint(equalTo: heightAnchor),

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

    private func makeTrayIconButton(systemName: String, toolTip: String) -> NSButton {
        let button = NSButton()
        configureTrayIconButton(button, systemName: systemName, toolTip: toolTip)
        return button
    }

    private func configureTrayIconButton(_ button: NSButton, systemName: String, toolTip: String) {
        button.image = NSImage(systemSymbolName: systemName, accessibilityDescription: toolTip)
        button.bezelStyle = .inline
        button.isBordered = false
        button.toolTip = toolTip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
    }

    private func refreshVolumeIcon() {
        let name = VolumeService.speakerSymbolName()
        volumeButton.image = NSImage(systemSymbolName: name, accessibilityDescription: "Volume")
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

    @objc private func openSettings() { onOpenSettings?() }

    @objc private func toggleWiFiMenu() {
        VolumePanelController.shared.hide()
        WiFiPanelController.shared.toggle(relativeTo: wifiButton)
    }

    @objc private func toggleVolumeSlider() {
        WiFiPanelController.shared.hide()
        VolumePanelController.shared.toggle(relativeTo: volumeButton)
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
