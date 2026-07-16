import AppKit

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Better Mac Taskbar"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = SettingsView(frame: window.contentView!.bounds)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.setActivationPolicy(.accessory)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let view = window?.contentView as? SettingsView {
            view.reloadHiddenList()
            view.reloadHotkeyDisplay()
        }
    }
}

final class SettingsView: NSView {
    private let centerCheckbox = NSButton(checkboxWithTitle: "Center taskbar icons", target: nil, action: nil)
    private let dockCheckbox = NSButton(checkboxWithTitle: "Hide Dock (use taskbar instead)", target: nil, action: nil)
    private let autoHideCheckbox = NSButton(checkboxWithTitle: "Automatically hide the taskbar", target: nil, action: nil)
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let hotkeyLabel = NSTextField(labelWithString: "Start menu hotkey")
    private let hotkeyButton = NSButton(title: "", target: nil, action: nil)
    private let hotkeyResetButton = NSButton(title: "Reset", target: nil, action: nil)
    private let hiddenSectionLabel = NSTextField(labelWithString: "Always hide on taskbar")
    private let hiddenEmptyLabel = NSTextField(labelWithString: "No apps hidden. Right-click a taskbar icon to add one.")
    private let hiddenScroll = NSScrollView()
    private let hiddenStack = NSStackView()

    private var isRecordingHotkey = false
    private var recordingFlagsMonitor: Any?
    private var recordingKeyMonitor: Any?
    private var recordingModifierKeyCode: UInt16?
    private var recordingSawNonModifier = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]

        let title = NSTextField(labelWithString: "Settings")
        title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        title.frame = NSRect(x: 24, y: frameRect.height - 48, width: 300, height: 28)
        title.autoresizingMask = [.minYMargin]
        addSubview(title)

        centerCheckbox.state = TaskbarSettings.shared.centerIcons ? .on : .off
        centerCheckbox.target = self
        centerCheckbox.action = #selector(centerChanged)
        centerCheckbox.frame = NSRect(x: 24, y: frameRect.height - 100, width: 300, height: 24)
        centerCheckbox.autoresizingMask = [.minYMargin]
        addSubview(centerCheckbox)

        dockCheckbox.state = TaskbarSettings.shared.replaceDock ? .on : .off
        dockCheckbox.target = self
        dockCheckbox.action = #selector(dockChanged)
        dockCheckbox.frame = NSRect(x: 24, y: frameRect.height - 136, width: 300, height: 24)
        dockCheckbox.autoresizingMask = [.minYMargin]
        addSubview(dockCheckbox)

        autoHideCheckbox.state = TaskbarSettings.shared.autoHideTaskbar ? .on : .off
        autoHideCheckbox.target = self
        autoHideCheckbox.action = #selector(autoHideChanged)
        autoHideCheckbox.frame = NSRect(x: 24, y: frameRect.height - 172, width: 340, height: 24)
        autoHideCheckbox.autoresizingMask = [.minYMargin]
        addSubview(autoHideCheckbox)

        launchAtLoginCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(launchAtLoginChanged)
        launchAtLoginCheckbox.frame = NSRect(x: 24, y: frameRect.height - 208, width: 340, height: 24)
        launchAtLoginCheckbox.autoresizingMask = [.minYMargin]
        addSubview(launchAtLoginCheckbox)

        hotkeyLabel.font = NSFont.systemFont(ofSize: 13)
        hotkeyLabel.frame = NSRect(x: 24, y: frameRect.height - 250, width: 140, height: 24)
        hotkeyLabel.autoresizingMask = [.minYMargin]
        addSubview(hotkeyLabel)

        hotkeyButton.bezelStyle = .rounded
        hotkeyButton.target = self
        hotkeyButton.action = #selector(beginHotkeyRecording)
        hotkeyButton.frame = NSRect(x: 170, y: frameRect.height - 252, width: 150, height: 28)
        hotkeyButton.autoresizingMask = [.minYMargin]
        hotkeyButton.toolTip = "Click, then press the shortcut you want for Start"
        addSubview(hotkeyButton)

        hotkeyResetButton.bezelStyle = .rounded
        hotkeyResetButton.target = self
        hotkeyResetButton.action = #selector(resetHotkey)
        hotkeyResetButton.frame = NSRect(x: 328, y: frameRect.height - 252, width: 68, height: 28)
        hotkeyResetButton.autoresizingMask = [.minYMargin]
        hotkeyResetButton.toolTip = "Reset to ⌘ / Windows key"
        addSubview(hotkeyResetButton)

        hiddenSectionLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        hiddenSectionLabel.frame = NSRect(x: 24, y: frameRect.height - 300, width: 300, height: 20)
        hiddenSectionLabel.autoresizingMask = [.minYMargin]
        addSubview(hiddenSectionLabel)

        hiddenEmptyLabel.font = NSFont.systemFont(ofSize: 12)
        hiddenEmptyLabel.textColor = .secondaryLabelColor
        hiddenEmptyLabel.frame = NSRect(x: 24, y: frameRect.height - 324, width: 370, height: 18)
        hiddenEmptyLabel.autoresizingMask = [.minYMargin]
        addSubview(hiddenEmptyLabel)

        hiddenStack.orientation = .vertical
        hiddenStack.alignment = .leading
        hiddenStack.spacing = 4
        hiddenStack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        hiddenStack.translatesAutoresizingMaskIntoConstraints = false

        let document = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 100))
        document.addSubview(hiddenStack)
        NSLayoutConstraint.activate([
            hiddenStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            hiddenStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            hiddenStack.topAnchor.constraint(equalTo: document.topAnchor),
            hiddenStack.widthAnchor.constraint(equalTo: document.widthAnchor)
        ])

        hiddenScroll.documentView = document
        hiddenScroll.hasVerticalScroller = true
        hiddenScroll.hasHorizontalScroller = false
        hiddenScroll.autohidesScrollers = true
        hiddenScroll.borderType = .bezelBorder
        hiddenScroll.drawsBackground = true
        hiddenScroll.backgroundColor = NSColor.controlBackgroundColor
        hiddenScroll.frame = NSRect(x: 24, y: 100, width: 372, height: frameRect.height - 440)
        hiddenScroll.autoresizingMask = [.width, .height]
        addSubview(hiddenScroll)

        let axNote = NSTextField(wrappingLabelWithString: "Grant Accessibility in System Settings → Privacy & Security so each window (including Chrome) appears as a separate icon.")
        axNote.maximumNumberOfLines = 0
        axNote.preferredMaxLayoutWidth = 370
        axNote.frame = NSRect(x: 24, y: 16, width: 370, height: 72)
        axNote.textColor = .secondaryLabelColor
        axNote.font = NSFont.systemFont(ofSize: 12)
        axNote.autoresizingMask = [.maxYMargin]
        addSubview(axNote)

        NotificationCenter.default.addObserver(self, selector: #selector(reloadHiddenList), name: .hiddenAppsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadHotkeyDisplay), name: .startMenuHotkeyChanged, object: nil)
        reloadHiddenList()
        reloadHotkeyDisplay()
    }

    deinit {
        stopHotkeyRecording(restoreTitle: false)
        NotificationCenter.default.removeObserver(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func reloadHotkeyDisplay() {
        guard !isRecordingHotkey else { return }
        hotkeyButton.title = TaskbarSettings.shared.startMenuHotkey.displayString
    }

    @objc func reloadHiddenList() {
        hiddenStack.arrangedSubviews.forEach {
            hiddenStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let ids = TaskbarSettings.shared.hiddenBundleIDs
        hiddenEmptyLabel.isHidden = !ids.isEmpty
        hiddenScroll.isHidden = ids.isEmpty

        for bundleID in ids {
            let row = makeHiddenRow(bundleID: bundleID)
            hiddenStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: hiddenStack.widthAnchor, constant: -8).isActive = true
        }

        hiddenStack.layoutSubtreeIfNeeded()
        if let document = hiddenScroll.documentView {
            let height = max(hiddenStack.fittingSize.height + 8, 40)
            document.setFrameSize(NSSize(width: hiddenScroll.contentSize.width, height: height))
            hiddenStack.frame = NSRect(x: 0, y: max(0, height - hiddenStack.fittingSize.height - 8), width: document.bounds.width, height: hiddenStack.fittingSize.height + 8)
        }
    }

    private func makeHiddenRow(bundleID: String) -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 28))
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.image = PinManager.icon(forBundleID: bundleID)
        icon.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(icon)

        let name = NSTextField(labelWithString: PinManager.appName(forBundleID: bundleID))
        name.font = NSFont.systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(name)

        let remove = NSButton(title: "Show", target: self, action: #selector(showHiddenApp(_:)))
        remove.bezelStyle = .rounded
        remove.controlSize = .small
        remove.identifier = NSUserInterfaceItemIdentifier(bundleID)
        remove.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(remove)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),

            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: remove.leadingAnchor, constant: -8),

            remove.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4),
            remove.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])

        return row
    }

    @objc private func showHiddenApp(_ sender: NSButton) {
        HideManager.removeHidden(bundleID: sender.identifier?.rawValue ?? "")
    }

    @objc private func centerChanged() {
        TaskbarSettings.shared.centerIcons = centerCheckbox.state == .on
    }

    @objc private func dockChanged() {
        TaskbarSettings.shared.replaceDock = dockCheckbox.state == .on
        if TaskbarSettings.shared.replaceDock {
            DockManager.enableReplaceMode()
        } else {
            DockManager.restoreDock()
        }
    }

    @objc private func autoHideChanged() {
        TaskbarSettings.shared.autoHideTaskbar = autoHideCheckbox.state == .on
    }

    @objc private func launchAtLoginChanged() {
        let want = launchAtLoginCheckbox.state == .on
        if !LaunchAtLogin.setEnabled(want) {
            launchAtLoginCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
        }
    }

    @objc private func resetHotkey() {
        stopHotkeyRecording(restoreTitle: false)
        TaskbarSettings.shared.startMenuHotkey = .default
        reloadHotkeyDisplay()
    }

    @objc private func beginHotkeyRecording() {
        if isRecordingHotkey {
            stopHotkeyRecording(restoreTitle: true)
            return
        }

        isRecordingHotkey = true
        recordingModifierKeyCode = nil
        recordingSawNonModifier = false
        StartHotkeyMonitor.shared.isSuspended = true
        hotkeyButton.title = "Press keys…"
        hotkeyButton.highlight(true)

        recordingKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleRecordingKeyDown(event) ?? event
        }
        recordingFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleRecordingFlagsChanged(event) ?? event
        }
    }

    private func handleRecordingKeyDown(_ event: NSEvent) -> NSEvent? {
        guard isRecordingHotkey else { return event }

        if event.keyCode == 53 { // Escape cancels
            stopHotkeyRecording(restoreTitle: true)
            return nil
        }

        if StartMenuHotkey.modifierFlag(forKeyCode: event.keyCode) != nil {
            return nil
        }

        recordingSawNonModifier = true
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        finishRecording(StartMenuHotkey(
            keyCode: event.keyCode,
            modifierFlags: mods.rawValue,
            modifierOnly: false
        ))
        return nil
    }

    private func handleRecordingFlagsChanged(_ event: NSEvent) -> NSEvent? {
        guard isRecordingHotkey else { return event }
        guard let flag = StartMenuHotkey.modifierFlag(forKeyCode: event.keyCode) else { return nil }

        let down = event.modifierFlags.contains(flag)
        if down {
            recordingModifierKeyCode = event.keyCode
            recordingSawNonModifier = false
            return nil
        }

        // Modifier released alone → treat as modifier-only Start key (e.g. ⌘ / Windows).
        if let pressed = recordingModifierKeyCode,
           StartMenuHotkey.isSameModifierKey(pressed, event.keyCode),
           !recordingSawNonModifier {
            finishRecording(StartMenuHotkey(
                keyCode: pressed,
                modifierFlags: flag.rawValue,
                modifierOnly: true
            ))
        }
        return nil
    }

    private func finishRecording(_ hotkey: StartMenuHotkey) {
        TaskbarSettings.shared.startMenuHotkey = hotkey
        stopHotkeyRecording(restoreTitle: false)
        reloadHotkeyDisplay()
        AppLog.info("startMenuHotkey set", ["hotkey": hotkey.displayString])
    }

    private func stopHotkeyRecording(restoreTitle: Bool) {
        if let recordingKeyMonitor {
            NSEvent.removeMonitor(recordingKeyMonitor)
            self.recordingKeyMonitor = nil
        }
        if let recordingFlagsMonitor {
            NSEvent.removeMonitor(recordingFlagsMonitor)
            self.recordingFlagsMonitor = nil
        }
        isRecordingHotkey = false
        recordingModifierKeyCode = nil
        recordingSawNonModifier = false
        StartHotkeyMonitor.shared.isSuspended = false
        hotkeyButton.highlight(false)
        if restoreTitle {
            reloadHotkeyDisplay()
        }
    }
}
