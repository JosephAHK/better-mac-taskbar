import AppKit
import QuartzCore

final class TaskbarPanelController {
    static let shared = TaskbarPanelController()

    private var panels: [ObjectIdentifier: (panel: NSPanel, screen: NSScreen)] = [:]
    private var contentViews: [ObjectIdentifier: TaskbarContentView] = [:]
    private var observersRegistered = false

    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var hideTimer: Timer?
    private var keepVisibleCount = 0
    private var revealedIDs: Set<ObjectIdentifier> = []

    private let peekHeight: CGFloat = 2
    private let hotZoneWhenHidden: CGFloat = 8
    private let hideDelay: TimeInterval = 0.45
    private let animationDuration: TimeInterval = 0.18

    func show() {
        AppLog.info("TaskbarPanel.show", ["screens": NSScreen.screens.count])
        rebuild()
        guard !observersRegistered else { return }
        observersRegistered = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: .taskbarSettingsChanged,
            object: nil
        )
    }

    func hide() {
        AppLog.info("TaskbarPanel.hide")
        stopMouseMonitoring()
        cancelHideTimer()
        for entry in panels.values {
            entry.panel.orderOut(nil)
        }
        panels.removeAll()
        contentViews.removeAll()
        revealedIDs.removeAll()
    }

    /// Keep the bar visible while overlays (Start, Downloads) are open.
    /// Reveals immediately (no slide-in) so Start anchors at the correct position.
    func beginKeepVisible() {
        keepVisibleCount += 1
        cancelHideTimer()
        revealAll(animated: false)
    }

    func endKeepVisible() {
        keepVisibleCount = max(0, keepVisibleCount - 1)
        if keepVisibleCount == 0 {
            handleMouseLocation(NSEvent.mouseLocation)
        }
    }

    /// Windows-style Start key: snap the taskbar visible and toggle Start on the screen under the cursor.
    func toggleStartMenu() {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let targetID = screen.map { ObjectIdentifier($0) }
        let target = targetID.flatMap { contentViews[$0] } ?? contentViews.values.first

        for (id, content) in contentViews {
            if id != targetID, content.isStartMenuVisible {
                content.hideStartMenu()
            }
        }

        let opening = target.map { !$0.isStartMenuVisible } ?? true
        if opening {
            cancelHideTimer()
            revealAll(animated: false)
        }
        target?.toggleStartMenuFromHotkey()
    }

    @objc private func screensChanged() {
        rebuild()
    }

    @objc private func settingsChanged() {
        rebuild()
    }

    private func rebuild() {
        hide()
        for screen in NSScreen.screens {
            let panel = makePanel(for: screen)
            let id = ObjectIdentifier(screen)
            panels[id] = (panel, screen)
            revealedIDs.insert(id)
            panel.orderFrontRegardless()
        }
        applyAutoHideMode()
    }

    private func applyAutoHideMode() {
        if TaskbarSettings.shared.autoHideTaskbar {
            startMouseMonitoring()
            for id in panels.keys {
                setRevealed(false, for: id, animated: false)
            }
            handleMouseLocation(NSEvent.mouseLocation)
        } else {
            stopMouseMonitoring()
            cancelHideTimer()
            for id in panels.keys {
                setRevealed(true, for: id, animated: false)
            }
        }
    }

    private func makePanel(for screen: NSScreen) -> NSPanel {
        let height = TaskbarSettings.shared.barHeight
        let visible = screen.frame
        let frame = NSRect(
            x: visible.origin.x,
            y: visible.origin.y,
            width: visible.width,
            height: height
        )

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // isFloatingPanel resets level to .floating — set false, then set level.
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.level = .statusBar

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active

        let tint = NSView(frame: effect.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        effect.addSubview(tint)

        let content = TaskbarContentView(frame: effect.bounds)
        content.autoresizingMask = [.width, .height]
        effect.addSubview(content)
        contentViews[ObjectIdentifier(screen)] = content

        let line = NSView(frame: NSRect(x: 0, y: height - 1, width: frame.width, height: 1))
        line.autoresizingMask = [.width, .minYMargin]
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        effect.addSubview(line)

        panel.contentView = effect
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        return panel
    }

    // MARK: - Auto-hide

    private func startMouseMonitoring() {
        stopMouseMonitoring()
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
            self?.handleMouseLocation(NSEvent.mouseLocation)
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            self?.handleMouseLocation(NSEvent.mouseLocation)
        }
    }

    private func stopMouseMonitoring() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func handleMouseLocation(_ point: NSPoint) {
        guard TaskbarSettings.shared.autoHideTaskbar else { return }

        if keepVisibleCount > 0 {
            cancelHideTimer()
            revealAll(animated: true)
            return
        }

        var hoveringAny = false
        for (id, entry) in panels {
            let height = TaskbarSettings.shared.barHeight
            let revealed = revealedIDs.contains(id)
            let zoneHeight = revealed ? height + 4 : hotZoneWhenHidden
            let hotZone = NSRect(
                x: entry.screen.frame.minX,
                y: entry.screen.frame.minY,
                width: entry.screen.frame.width,
                height: zoneHeight
            )
            if hotZone.contains(point) {
                hoveringAny = true
                cancelHideTimer()
                setRevealed(true, for: id, animated: true)
            }
        }

        if !hoveringAny {
            scheduleHideAll()
        }
    }

    private func scheduleHideAll() {
        guard hideTimer == nil else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: hideDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.hideTimer = nil
            guard self.keepVisibleCount == 0 else { return }
            let point = NSEvent.mouseLocation
            for (id, entry) in self.panels {
                let height = TaskbarSettings.shared.barHeight
                let hotZone = NSRect(
                    x: entry.screen.frame.minX,
                    y: entry.screen.frame.minY,
                    width: entry.screen.frame.width,
                    height: height + 4
                )
                if !hotZone.contains(point) {
                    self.setRevealed(false, for: id, animated: true)
                }
            }
        }
        if let hideTimer {
            RunLoop.main.add(hideTimer, forMode: .common)
        }
    }

    private func cancelHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private func revealAll(animated: Bool) {
        for id in panels.keys {
            setRevealed(true, for: id, animated: animated)
        }
    }

    private func setRevealed(_ revealed: Bool, for id: ObjectIdentifier, animated: Bool) {
        guard let entry = panels[id] else { return }
        let currentlyRevealed = revealedIDs.contains(id)
        if revealed == currentlyRevealed {
            if animated { return }
        }
        if revealed {
            revealedIDs.insert(id)
        } else {
            revealedIDs.remove(id)
        }

        let height = TaskbarSettings.shared.barHeight
        let screen = entry.screen
        let targetY = revealed
            ? screen.frame.minY
            : screen.frame.minY - (height - peekHeight)
        var frame = entry.panel.frame
        frame.origin.x = screen.frame.minX
        frame.origin.y = targetY
        frame.size.width = screen.frame.width
        frame.size.height = height

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                entry.panel.animator().setFrame(frame, display: true)
            }
        } else {
            entry.panel.setFrame(frame, display: true)
        }
    }
}
