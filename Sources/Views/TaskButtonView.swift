import AppKit
import ApplicationServices

protocol TaskbarIconDragDelegate: AnyObject {
    func taskbarIconMouseDown(_ view: NSView, event: NSEvent)
    func taskbarIconMouseDragged(_ view: NSView, event: NSEvent)
    func taskbarIconMouseUp(_ view: NSView, event: NSEvent)
}

protocol TaskbarOrderable {
    var orderKey: String { get }
    /// Extra key written next to `orderKey` so the slot keeps its place after the
    /// window id changes (app quit/relaunch, or a pinned icon becoming a window).
    var orderAliasKey: String? { get }
}

extension TaskbarOrderable {
    var orderAliasKey: String? { nil }
}

/// Context menus from a bottom-edge `.nonactivatingPanel` mis-place with
/// `popUpContextMenu` (stuck to the screen bottom). Pop upward from the icon instead.
fileprivate func popUpTaskbarIconMenu(_ menu: NSMenu, with event: NSEvent, in view: NSView) {
    TaskbarPanelController.shared.beginKeepVisible()
    defer { TaskbarPanelController.shared.endKeepVisible() }

    let local = view.convert(event.locationInWindow, from: nil)
    // Top of the icon — AppKit grows the menu downward from this point, then flips
    // it above the taskbar when there isn't room below (screen edge).
    let anchor = NSPoint(x: local.x, y: view.bounds.maxY)
    menu.popUp(positioning: nil, at: anchor, in: view)
}

final class TaskButtonView: NSView, TaskbarOrderable {
    private(set) var windowInfo: WindowInfo
    var onActivate: ((WindowInfo) -> Void)?
    var onClose: ((WindowInfo) -> Void)?
    var onMinimize: ((WindowInfo) -> Void)?
    var onPinToggle: ((WindowInfo) -> Void)?
    var onHideToggle: ((WindowInfo) -> Void)?
    var onQuit: ((WindowInfo) -> Void)?
    var onNewWindow: ((WindowInfo) -> Void)?
    weak var dragDelegate: TaskbarIconDragDelegate?

    var orderKey: String { windowInfo.id }
    var orderAliasKey: String? { windowInfo.bundleID }

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let underline = NSView()
    private var tracking: NSTrackingArea?
    private let style: TaskbarButtonStyle
    private let barHeight: CGFloat

    init(windowInfo: WindowInfo, height: CGFloat, width: CGFloat, style: TaskbarButtonStyle) {
        self.windowInfo = windowInfo
        self.style = style
        self.barHeight = height
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        setup()
        toolTip = windowInfo.displayTitle
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 3
        addSubview(iconView)

        titleLabel.font = NSFont.systemFont(ofSize: 12)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isHidden = !style.showsTitle
        addSubview(titleLabel)

        if let app = NSRunningApplication(processIdentifier: windowInfo.pid) {
            iconView.image = app.icon
        } else if let bid = windowInfo.bundleID {
            iconView.image = PinManager.icon(forBundleID: bid)
        }

        underline.wantsLayer = true
        underline.layer?.backgroundColor = NSColor(calibratedRed: 0, green: 0.47, blue: 0.84, alpha: 1).cgColor
        underline.layer?.cornerRadius = 1
        addSubview(underline)
        titleLabel.stringValue = Self.labelText(for: windowInfo)
        layoutContents()
        updateUnderline()
    }

    func apply(_ info: WindowInfo) {
        windowInfo = info
        toolTip = info.displayTitle
        if style.showsTitle {
            titleLabel.stringValue = Self.labelText(for: info)
        }
        updateUnderline()
    }

    /// Window title where we have one, otherwise the app name — the app name is
    /// already implied by the icon, so the document title is the useful part.
    private static func labelText(for info: WindowInfo) -> String {
        info.title.isEmpty ? info.appName : info.title
    }

    override func layout() {
        super.layout()
        layoutContents()
        updateUnderline()
    }

    private func layoutContents() {
        let iconSize = max(18, min(barHeight * 0.55, 36))
        if style.showsTitle {
            let inset: CGFloat = 10
            iconView.frame = NSRect(
                x: inset,
                y: (bounds.height - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )
            let textX = iconView.frame.maxX + 8
            titleLabel.frame = NSRect(
                x: textX,
                y: (bounds.height - 16) / 2 - 1,
                width: max(bounds.width - textX - inset, 0),
                height: 16
            )
        } else {
            iconView.frame = NSRect(
                x: (bounds.width - iconSize) / 2,
                y: (bounds.height - iconSize) / 2 + 1,
                width: iconSize,
                height: iconSize
            )
        }
    }

    func updateUnderline() {
        let width = bounds.width
        // Labeled buttons are wide, so the accent hugs the edges more tightly
        // than the square icons do (matching the Windows 10 look).
        let activeInset: CGFloat = style.showsTitle ? 4 : 10
        let idleInset: CGFloat = style.showsTitle ? 8 : 18
        if windowInfo.isActive {
            underline.layer?.backgroundColor = NSColor(calibratedRed: 0, green: 0.47, blue: 0.84, alpha: 1).cgColor
            underline.frame = NSRect(x: activeInset, y: 0, width: max(width - activeInset * 2, 8), height: 4)
            underline.isHidden = false
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        } else {
            underline.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.45).cgColor
            underline.frame = NSRect(x: idleInset, y: 0, width: max(width - idleInset * 2, 6), height: 3)
            underline.isHidden = false
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        tracking = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) {
        if !windowInfo.isActive {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        updateUnderline()
    }

    override func mouseDown(with event: NSEvent) {
        dragDelegate?.taskbarIconMouseDown(self, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        dragDelegate?.taskbarIconMouseDragged(self, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        dragDelegate?.taskbarIconMouseUp(self, event: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        // Middle-click closes (Windows behavior)
        if event.buttonNumber == 2 {
            onClose?(windowInfo)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let titleItem = NSMenuItem(title: truncate(windowInfo.displayTitle, 42), action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(.separator())

        let pinned = PinManager.isPinned(windowInfo.bundleID)
        let pin = NSMenuItem(
            title: pinned ? "Unpin from taskbar" : "Pin this program to taskbar",
            action: #selector(pinToggle),
            keyEquivalent: ""
        )
        pin.target = self
        pin.isEnabled = windowInfo.bundleID != nil
        menu.addItem(pin)

        let hidden = HideManager.isHidden(windowInfo.bundleID)
        let hide = NSMenuItem(
            title: hidden ? "Show on taskbar" : "Always hide on taskbar",
            action: #selector(hideToggle),
            keyEquivalent: ""
        )
        hide.target = self
        hide.isEnabled = windowInfo.bundleID != nil
        menu.addItem(hide)
        menu.addItem(.separator())

        let close = NSMenuItem(title: "Close window", action: #selector(closeWindow), keyEquivalent: "")
        close.target = self
        close.isEnabled = true
        menu.addItem(close)

        let minimize = NSMenuItem(title: "Minimize", action: #selector(minimizeWindow), keyEquivalent: "")
        minimize.target = self
        minimize.isEnabled = true
        menu.addItem(minimize)
        menu.addItem(.separator())

        let newWindow = NSMenuItem(title: "New window", action: #selector(newWindowAction), keyEquivalent: "")
        newWindow.target = self
        newWindow.isEnabled = windowInfo.bundleID != nil
        menu.addItem(newWindow)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit \(windowInfo.appName)", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        popUpTaskbarIconMenu(menu, with: event, in: self)
    }

    @objc private func pinToggle() { onPinToggle?(windowInfo) }
    @objc private func hideToggle() { onHideToggle?(windowInfo) }
    @objc private func closeWindow() { onClose?(windowInfo) }
    @objc private func minimizeWindow() { onMinimize?(windowInfo) }
    @objc private func newWindowAction() { onNewWindow?(windowInfo) }
    @objc private func quitApp() { onQuit?(windowInfo) }

    private func truncate(_ text: String, _ max: Int) -> String {
        guard text.count > max else { return text }
        return String(text.prefix(max - 1)) + "…"
    }
}

final class PinnedButtonView: NSView, TaskbarOrderable {
    let bundleID: String
    var onLaunch: ((String) -> Void)?
    var onUnpin: ((String) -> Void)?
    var onHide: ((String) -> Void)?
    weak var dragDelegate: TaskbarIconDragDelegate?

    var orderKey: String { bundleID }

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var tracking: NSTrackingArea?
    private let style: TaskbarButtonStyle
    private let barHeight: CGFloat
    private(set) var isLaunching = false

    init(bundleID: String, height: CGFloat, width: CGFloat, style: TaskbarButtonStyle) {
        self.bundleID = bundleID
        self.style = style
        self.barHeight = height
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = PinManager.icon(forBundleID: bundleID)
        iconView.wantsLayer = true
        addSubview(iconView)

        titleLabel.font = NSFont.systemFont(ofSize: 12)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.stringValue = PinManager.appName(forBundleID: bundleID)
        titleLabel.isHidden = !style.showsTitle
        addSubview(titleLabel)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)

        layoutContents()
        toolTip = PinManager.appName(forBundleID: bundleID)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows the "opening" state: spinner under a dimmed, pulsing icon, matching
    /// Windows' feedback for the gap between click and first window.
    func setLaunching(_ launching: Bool) {
        guard launching != isLaunching else { return }
        isLaunching = launching
        toolTip = launching
            ? "Opening \(PinManager.appName(forBundleID: bundleID))…"
            : PinManager.appName(forBundleID: bundleID)

        if launching {
            spinner.startAnimation(nil)
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.85
            pulse.toValue = 0.35
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            iconView.layer?.add(pulse, forKey: "launchPulse")
        } else {
            spinner.stopAnimation(nil)
            iconView.layer?.removeAnimation(forKey: "launchPulse")
            iconView.layer?.opacity = 1
        }
    }

    override func layout() {
        super.layout()
        layoutContents()
    }

    private func layoutContents() {
        let iconSize = max(18, min(barHeight * 0.55, 36))
        if style.showsTitle {
            let inset: CGFloat = 10
            iconView.frame = NSRect(x: inset, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
            let textX = iconView.frame.maxX + 8
            titleLabel.frame = NSRect(
                x: textX,
                y: (bounds.height - 16) / 2 - 1,
                width: max(bounds.width - textX - inset, 0),
                height: 16
            )
        } else {
            iconView.frame = NSRect(
                x: (bounds.width - iconSize) / 2,
                y: (bounds.height - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )
        }

        // Spinner sits under whichever position the icon ended up in.
        let spinnerSize: CGFloat = 12
        spinner.frame = NSRect(
            x: iconView.frame.midX - spinnerSize / 2,
            y: 1,
            width: spinnerSize,
            height: spinnerSize
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        dragDelegate?.taskbarIconMouseDown(self, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        dragDelegate?.taskbarIconMouseDragged(self, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        dragDelegate?.taskbarIconMouseUp(self, event: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let unpin = NSMenuItem(title: "Unpin from taskbar", action: #selector(unpin), keyEquivalent: "")
        unpin.target = self
        menu.addItem(unpin)

        let hide = NSMenuItem(title: "Always hide on taskbar", action: #selector(hideApp), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)

        let open = NSMenuItem(title: "Open", action: #selector(openApp), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        popUpTaskbarIconMenu(menu, with: event, in: self)
    }

    @objc private func unpin() { onUnpin?(bundleID) }
    @objc private func hideApp() { onHide?(bundleID) }
    @objc private func openApp() { onLaunch?(bundleID) }
}
