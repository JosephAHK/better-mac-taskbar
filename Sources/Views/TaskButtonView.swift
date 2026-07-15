import AppKit
import ApplicationServices

protocol TaskbarIconDragDelegate: AnyObject {
    func taskbarIconMouseDown(_ view: NSView, event: NSEvent)
    func taskbarIconMouseDragged(_ view: NSView, event: NSEvent)
    func taskbarIconMouseUp(_ view: NSView, event: NSEvent)
}

protocol TaskbarOrderable {
    var orderKey: String { get }
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

    private let iconView = NSImageView()
    private let underline = NSView()
    private var tracking: NSTrackingArea?

    init(windowInfo: WindowInfo, size: CGFloat) {
        self.windowInfo = windowInfo
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        setup(size: size)
        toolTip = windowInfo.displayTitle
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup(size: CGFloat) {
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 3
        addSubview(iconView)

        let iconSize = max(18, min(size * 0.55, 36))
        iconView.frame = NSRect(
            x: (size - iconSize) / 2,
            y: (size - iconSize) / 2 + 1,
            width: iconSize,
            height: iconSize
        )

        if let app = NSRunningApplication(processIdentifier: windowInfo.pid) {
            iconView.image = app.icon
        } else if let bid = windowInfo.bundleID {
            iconView.image = PinManager.icon(forBundleID: bid)
        }

        underline.wantsLayer = true
        underline.layer?.backgroundColor = NSColor(calibratedRed: 0, green: 0.47, blue: 0.84, alpha: 1).cgColor
        underline.layer?.cornerRadius = 1
        addSubview(underline)
        updateUnderline()
    }

    func apply(_ info: WindowInfo) {
        windowInfo = info
        toolTip = info.displayTitle
        updateUnderline()
    }

    func updateUnderline() {
        let width = bounds.width
        if windowInfo.isActive {
            underline.layer?.backgroundColor = NSColor(calibratedRed: 0, green: 0.47, blue: 0.84, alpha: 1).cgColor
            underline.frame = NSRect(x: 10, y: 0, width: max(width - 20, 8), height: 4)
            underline.isHidden = false
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        } else {
            underline.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.45).cgColor
            underline.frame = NSRect(x: 18, y: 0, width: max(width - 36, 6), height: 3)
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

        NSMenu.popUpContextMenu(menu, with: event, for: self)
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
    private var tracking: NSTrackingArea?

    init(bundleID: String, size: CGFloat) {
        self.bundleID = bundleID
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = PinManager.icon(forBundleID: bundleID)
        let iconSize = max(18, min(size * 0.55, 36))
        iconView.frame = NSRect(x: (size - iconSize) / 2, y: (size - iconSize) / 2, width: iconSize, height: iconSize)
        addSubview(iconView)
        toolTip = PinManager.appName(forBundleID: bundleID)
    }

    required init?(coder: NSCoder) { fatalError() }

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
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func unpin() { onUnpin?(bundleID) }
    @objc private func hideApp() { onHide?(bundleID) }
    @objc private func openApp() { onLaunch?(bundleID) }
}
