import AppKit

private final class WiFiKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class WiFiPanelController {
    static let shared = WiFiPanelController()

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
        panel?.orderOut(nil)
        panel = nil
        anchor = nil
        if wasVisible {
            TaskbarPanelController.shared.endKeepVisible()
        }
    }

    private func show(relativeTo view: NSView) {
        VolumePanelController.shared.hide()
        DownloadsPanelController.shared.hide()
        hide()
        guard let window = view.window else { return }

        let width: CGFloat = 300
        let height: CGFloat = 380
        let content = WiFiPanelView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.onRequestClose = { [weak self] in
            self?.hide()
        }
        content.onOpenSettings = { [weak self] in
            if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
            self?.hide()
        }

        let panel = WiFiKeyablePanel(
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

        let screenFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
        let x = min(
            max(screenFrame.maxX - width, screenFrame.minX),
            (window.screen?.visibleFrame.maxX ?? screenFrame.maxX) - width
        )
        let y = screenFrame.maxY + 2
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
        self.anchor = view
        installMonitors()
        TaskbarPanelController.shared.beginKeepVisible()
    }

    private func installMonitors() {
        removeMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {
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
        if let anchor, let window = anchor.window {
            let anchorScreen = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            if anchorScreen.contains(location) { return }
        }
        hide()
    }
}

final class WiFiPanelView: NSView {
    var onRequestClose: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let powerSwitch = NSSwitch()
    private let statusLabel = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var networks: [WiFiNetworkInfo] = []
    private var isBusy = false

    override init(frame frameRect: NSRect) {
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

        let title = NSTextField(labelWithString: "Wi‑Fi")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        powerSwitch.target = self
        powerSwitch.action = #selector(powerToggled)
        powerSwitch.translatesAutoresizingMaskIntoConstraints = false
        addSubview(powerSwitch)

        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        let refresh = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")!,
            target: self,
            action: #selector(refreshNetworks)
        )
        refresh.bezelStyle = .inline
        refresh.isBordered = false
        refresh.toolTip = "Refresh"
        refresh.translatesAutoresizingMaskIntoConstraints = false
        addSubview(refresh)

        let openButton = NSButton(title: "Network Settings…", target: self, action: #selector(openSettings))
        openButton.bezelStyle = .inline
        openButton.isBordered = false
        openButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        openButton.contentTintColor = NSColor(calibratedRed: 0.35, green: 0.72, blue: 1, alpha: 1)
        openButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(openButton)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4),
            stack.widthAnchor.constraint(equalTo: document.widthAnchor)
        ])
        scroll.documentView = document

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 12),

            powerSwitch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            powerSwitch.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: refresh.leadingAnchor, constant: -8),
            statusLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),

            refresh.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            refresh.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            refresh.widthAnchor.constraint(equalToConstant: 24),
            refresh.heightAnchor.constraint(equalToConstant: 24),

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: openButton.topAnchor, constant: -8),

            openButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            openButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            document.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -4)
        ])

        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func powerToggled() {
        WiFiService.isPoweredOn = powerSwitch.state == .on
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.reload()
        }
    }

    @objc private func refreshNetworks() {
        reload()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    private func reload() {
        let powered = WiFiService.isPoweredOn
        powerSwitch.state = powered ? .on : .off

        if !powered {
            statusLabel.stringValue = "Wi‑Fi is off"
            networks = []
            rebuildRows()
            return
        }

        if let ssid = WiFiService.currentSSID, !ssid.isEmpty {
            statusLabel.stringValue = "Connected to \(ssid)"
        } else {
            statusLabel.stringValue = "Not connected"
        }

        networks = WiFiService.scanNetworks()
        rebuildRows()
    }

    private func rebuildRows() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let powered = WiFiService.isPoweredOn
        if !powered {
            addEmptyMessage("Turn on Wi‑Fi to see networks")
            return
        }

        if networks.isEmpty {
            addEmptyMessage("No networks found\nLocation access may be required to scan")
            return
        }

        let rowWidth = max(bounds.width - 16, 270)
        for info in networks {
            let row = WiFiNetworkRow(info: info, width: rowWidth)
            row.onSelect = { [weak self] network in
                self?.connect(to: network)
            }
            row.onDisconnect = { [weak self] in
                WiFiService.disconnect()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self?.reload()
                }
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        }
    }

    private func addEmptyMessage(_ text: String) {
        let empty = NSTextField(wrappingLabelWithString: text)
        empty.font = NSFont.systemFont(ofSize: 12)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(empty)
        NSLayoutConstraint.activate([
            wrap.heightAnchor.constraint(equalToConstant: 90),
            empty.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            empty.leadingAnchor.constraint(greaterThanOrEqualTo: wrap.leadingAnchor, constant: 16),
            empty.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor, constant: -16),
            wrap.widthAnchor.constraint(equalToConstant: max(bounds.width - 16, 270))
        ])
        stack.addArrangedSubview(wrap)
    }

    private func connect(to network: WiFiNetworkInfo) {
        guard !isBusy else { return }
        if network.isCurrent {
            return
        }

        let finish: (String?) -> Void = { [weak self] errorMessage in
            DispatchQueue.main.async {
                self?.isBusy = false
                if let errorMessage {
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t connect to \(network.ssid)"
                    alert.informativeText = errorMessage
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
                self?.reload()
            }
        }

        if network.isSecure {
            let alert = NSAlert()
            alert.messageText = "Password for “\(network.ssid)”"
            alert.informativeText = "Enter the Wi‑Fi password to join this network."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Join")
            alert.addButton(withTitle: "Cancel")

            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            field.placeholderString = "Password"
            alert.accessoryView = field
            // Defer so the alert can become key before focusing the field.
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
            }

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }
            let password = field.stringValue
            isBusy = true
            statusLabel.stringValue = "Connecting to \(network.ssid)…"
            DispatchQueue.global(qos: .userInitiated).async {
                let error = WiFiService.connect(ssid: network.ssid, password: password)
                finish(error)
            }
        } else {
            isBusy = true
            statusLabel.stringValue = "Connecting to \(network.ssid)…"
            DispatchQueue.global(qos: .userInitiated).async {
                let error = WiFiService.connect(ssid: network.ssid, password: nil)
                finish(error)
            }
        }
    }
}

private final class WiFiNetworkRow: NSView {
    let info: WiFiNetworkInfo
    var onSelect: ((WiFiNetworkInfo) -> Void)?
    var onDisconnect: (() -> Void)?

    private var tracking: NSTrackingArea?

    init(info: WiFiNetworkInfo, width: CGFloat) {
        self.info = info
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 40))
        wantsLayer = true
        layer?.cornerRadius = 4

        let icon = NSImageView(frame: NSRect(x: 8, y: 8, width: 22, height: 22))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.image = NSImage(systemSymbolName: "wifi", accessibilityDescription: "Signal")
        icon.contentTintColor = info.isCurrent
            ? NSColor(calibratedRed: 0.35, green: 0.72, blue: 1, alpha: 1)
            : .secondaryLabelColor
        addSubview(icon)

        let name = NSTextField(labelWithString: info.ssid)
        name.font = NSFont.systemFont(ofSize: 13, weight: info.isCurrent ? .semibold : .regular)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.frame = NSRect(x: 38, y: 10, width: width - 100, height: 20)
        addSubview(name)

        var trailingX = width - 12
        if info.isSecure {
            let lock = NSImageView(frame: NSRect(x: trailingX - 16, y: 12, width: 14, height: 14))
            lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Secured")
            lock.contentTintColor = .tertiaryLabelColor
            lock.imageScaling = .scaleProportionallyUpOrDown
            addSubview(lock)
            trailingX -= 22
        }
        if info.isCurrent {
            let check = NSImageView(frame: NSRect(x: trailingX - 16, y: 11, width: 16, height: 16))
            check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Connected")
            check.contentTintColor = NSColor(calibratedRed: 0.35, green: 0.72, blue: 1, alpha: 1)
            check.imageScaling = .scaleProportionallyUpOrDown
            addSubview(check)
        }

        toolTip = info.isCurrent ? "Connected — click to disconnect" : "Join \(info.ssid)"
        heightAnchor.constraint(equalToConstant: 40).isActive = true
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
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseUp(with event: NSEvent) {
        if info.isCurrent {
            onDisconnect?()
        } else {
            onSelect?(info)
        }
    }
}
