import AppKit

private final class VolumeKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class VolumePanelController {
    static let shared = VolumePanelController()

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
        WiFiPanelController.shared.hide()
        DownloadsPanelController.shared.hide()
        hide()
        guard let window = view.window else { return }

        let width: CGFloat = 72
        let height: CGFloat = 220
        let content = VolumePanelView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.onRequestClose = { [weak self] in
            self?.hide()
        }
        content.onOpenSettings = { [weak self] in
            if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
            self?.hide()
        }

        let panel = VolumeKeyablePanel(
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
        let x = screenFrame.midX - width / 2
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

final class VolumePanelView: NSView {
    var onRequestClose: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let muteButton = NSButton()
    private let slider = NSSlider()
    private let percentLabel = NSTextField(labelWithString: "")
    private var pollTimer: Timer?

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

        muteButton.bezelStyle = .inline
        muteButton.isBordered = false
        muteButton.target = self
        muteButton.action = #selector(toggleMute)
        muteButton.toolTip = "Mute"
        muteButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(muteButton)

        slider.isVertical = true
        slider.minValue = 0
        slider.maxValue = 1
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slider)

        percentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        percentLabel.textColor = .secondaryLabelColor
        percentLabel.alignment = .center
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(percentLabel)

        let settings = NSButton(title: "⋯", target: self, action: #selector(openSettings))
        settings.bezelStyle = .inline
        settings.isBordered = false
        settings.toolTip = "Sound settings"
        settings.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        settings.contentTintColor = .secondaryLabelColor
        settings.translatesAutoresizingMaskIntoConstraints = false
        addSubview(settings)

        NSLayoutConstraint.activate([
            muteButton.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            muteButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            muteButton.widthAnchor.constraint(equalToConstant: 28),
            muteButton.heightAnchor.constraint(equalToConstant: 28),

            slider.topAnchor.constraint(equalTo: muteButton.bottomAnchor, constant: 8),
            slider.centerXAnchor.constraint(equalTo: centerXAnchor),
            slider.widthAnchor.constraint(equalToConstant: 28),
            slider.bottomAnchor.constraint(equalTo: percentLabel.topAnchor, constant: -6),

            percentLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            percentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            percentLabel.bottomAnchor.constraint(equalTo: settings.topAnchor, constant: -2),

            settings.centerXAnchor.constraint(equalTo: centerXAnchor),
            settings.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            settings.heightAnchor.constraint(equalToConstant: 20)
        ])

        refreshFromSystem()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.refreshFromSystem()
        }
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        pollTimer?.invalidate()
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        VolumeService.volume = Float(sender.doubleValue)
        refreshFromSystem(skipSlider: true)
    }

    @objc private func toggleMute() {
        VolumeService.toggleMute()
        refreshFromSystem()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    private func refreshFromSystem(skipSlider: Bool = false) {
        let muted = VolumeService.isMuted
        let vol = VolumeService.volume
        if !skipSlider {
            // Don't fight the user while dragging the slider.
            let leftDown = (NSEvent.pressedMouseButtons & (1 << 0)) != 0
            if !leftDown {
                slider.doubleValue = Double(vol)
            }
        }
        let display = muted ? 0 : Int(round(vol * 100))
        percentLabel.stringValue = "\(display)%"
        muteButton.image = NSImage(
            systemSymbolName: VolumeService.speakerSymbolName(),
            accessibilityDescription: muted ? "Unmute" : "Mute"
        )
        muteButton.toolTip = muted ? "Unmute" : "Mute"
    }
}
