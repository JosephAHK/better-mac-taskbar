import AppKit
import QuartzCore

@MainActor
final class TaskbarPanelController {
    static let shared = TaskbarPanelController()

    /// Panels are keyed by display ID rather than NSScreen identity: AppKit hands
    /// back fresh NSScreen objects after every screen-parameter change, so identity
    /// keys would make each change look like every screen was unplugged and replaced.
    private typealias ScreenKey = CGDirectDisplayID

    private struct Entry {
        let panel: NSPanel
        let content: TaskbarContentView
        var screen: NSScreen
    }

    private var entries: [ScreenKey: Entry] = [:]
    private var observersRegistered = false

    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var hideTimers: [ScreenKey: Timer] = [:]
    private var keepVisibleCount = 0
    private var revealedKeys: Set<ScreenKey> = []
    /// Auto-hide mode last applied. `.taskbarSettingsChanged` fires for every
    /// setting, and re-running the hide pass for an unrelated one would snap a
    /// revealed bar shut under the pointer.
    private var appliedAutoHide: Bool?
    /// Bars partway through an animated reveal, keyed to that reveal's generation so
    /// a reveal that was interrupted (by a hide, or a reframe) never reports settling.
    private var revealsInFlight: [ScreenKey: Int] = [:]
    private var revealGeneration = 0

    private let peekHeight: CGFloat = 2
    private let slideDuration: TimeInterval = 0.18
    /// Bars with a display stacked below fade in place rather than slide.
    private let fadeDuration: TimeInterval = 0.12

    /// Whether any screen's bar is on screen rather than auto-hidden away.
    var isBarVisible: Bool { !revealedKeys.isEmpty }

    /// Whether `window` is a bar that is fully revealed and not moving, so something
    /// anchored to it (the preview flyout) lands where the bar will stay.
    func isSettled(_ window: NSWindow) -> Bool {
        guard let key = entries.first(where: { $0.value.panel === window })?.key else { return false }
        return revealedKeys.contains(key) && revealsInFlight[key] == nil
    }

    func show() {
        AppLog.info("TaskbarPanel.show", ["screens": NSScreen.screens.count])
        syncPanels()
        DockBadgeMonitor.shared.start()
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
        closeOverlays(on: Array(entries.keys))
        DockBadgeMonitor.shared.stop()
        stopMouseMonitoring()
        cancelAllHideTimers()
        for entry in entries.values {
            entry.panel.orderOut(nil)
        }
        entries.removeAll()
        revealedKeys.removeAll()
        revealsInFlight.removeAll()
        appliedAutoHide = nil
        // Every overlay was just closed, so nothing can still legitimately hold the
        // bar open. Zeroing also recovers from an owner that went away without
        // balancing its begin, which would otherwise disable auto-hide for good.
        keepVisibleCount = 0
    }

    /// Keep the bar visible while overlays (Start, Downloads) are open.
    /// Reveals immediately (no slide-in) so Start anchors at the correct position.
    func beginKeepVisible() {
        keepVisibleCount += 1
        cancelAllHideTimers()
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
        let targetKey = screen.flatMap(Self.key(for:))
        let target = targetKey.flatMap { entries[$0]?.content } ?? entries.values.first?.content

        for (key, entry) in entries where key != targetKey && entry.content.isStartMenuVisible {
            entry.content.hideStartMenu()
        }

        let opening = target.map { !$0.isStartMenuVisible } ?? true
        if opening {
            cancelAllHideTimers()
            revealAll(animated: false)
        }
        target?.toggleStartMenuFromHotkey()
    }

    @objc private func screensChanged() {
        syncPanels()
    }

    @objc private func settingsChanged() {
        // Bar height is fixed and the content views reload themselves for layout
        // settings, so auto-hide is the only setting the panels act on.
        updateAutoHideMode()
    }

    private static func key(for screen: NSScreen) -> ScreenKey? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// Matches panels to the current screens. Existing panels are repositioned in
    /// place, so the frequent no-op notifications (Dock, menu bar, wake) keep open
    /// flyouts and in-progress drags; panels are only created or destroyed for
    /// screens that came or went.
    private func syncPanels() {
        var current: [ScreenKey: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let key = Self.key(for: screen) {
                current[key] = screen
            }
        }

        let removed = entries.keys.filter { current[$0] == nil }
        // Start and the flyouts are positioned once, when they open; a screen that
        // moved or changed resolution would leave them floating at the old spot.
        let resized = entries.compactMap { key, entry in
            current[key].flatMap { $0.frame != entry.screen.frame ? key : nil }
        }
        closeOverlays(on: removed + resized)
        for key in removed {
            cancelHideTimer(for: key)
            entries[key]?.panel.orderOut(nil)
            entries[key] = nil
            revealedKeys.remove(key)
            revealsInFlight[key] = nil
        }

        for (key, screen) in current {
            if var entry = entries[key] {
                entry.screen = screen
                entries[key] = entry
            } else {
                entries[key] = makeEntry(for: screen)
                if appliedAutoHide != true || keepVisibleCount > 0 {
                    revealedKeys.insert(key)
                }
            }
            // Recomputes the frame against the screen's new geometry.
            setRevealed(revealedKeys.contains(key), for: key, animated: false)
        }

        updateAutoHideMode()
        handleMouseLocation(NSEvent.mouseLocation)
    }

    /// Closes Start on the given screens plus the shared tray flyouts, so each
    /// overlay balances its `beginKeepVisible` before the view it is anchored to goes
    /// away or moves. The flyouts don't expose which screen they opened on, and
    /// screens being removed or resized is rare, so they are all closed.
    private func closeOverlays(on keys: [ScreenKey]) {
        guard !keys.isEmpty else { return }
        for key in keys {
            entries[key]?.content.hideStartMenu()
        }
        DownloadsPanelController.shared.hide()
        TrashPanelController.shared.hide()
        CalendarPanelController.shared.hide()
        WindowPreviewController.shared.hide()
    }

    private func updateAutoHideMode() {
        let autoHide = TaskbarSettings.shared.autoHideTaskbar
        guard autoHide != appliedAutoHide else { return }
        appliedAutoHide = autoHide
        if autoHide {
            startMouseMonitoring()
            if keepVisibleCount == 0 {
                for key in entries.keys {
                    setRevealed(false, for: key, animated: false)
                }
            }
            handleMouseLocation(NSEvent.mouseLocation)
        } else {
            stopMouseMonitoring()
            cancelAllHideTimers()
            revealAll(animated: false)
        }
    }

    private func makeEntry(for screen: NSScreen) -> Entry {
        let height = TaskbarSettings.shared.barHeight
        let frame = NSRect(
            x: screen.frame.origin.x,
            y: screen.frame.origin.y,
            width: screen.frame.width,
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
        // No .fullScreenAuxiliary: an all-Spaces window without it is left out of
        // native full-screen Spaces, so full-screen apps get the whole display the
        // way Windows hides its taskbar for them. .stationary keeps the bar in place
        // through Mission Control on ordinary Spaces.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.level = .statusBar
        // The Windows 10 taskbar is dark regardless of the system theme; pinning the
        // appearance makes every dynamic colour on the bar resolve to its dark variant.
        panel.appearance = NSAppearance(named: .darkAqua)

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

        let line = NSView(frame: NSRect(x: 0, y: height - 1, width: frame.width, height: 1))
        line.autoresizingMask = [.width, .minYMargin]
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        effect.addSubview(line)

        panel.contentView = effect
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        return Entry(panel: panel, content: content, screen: screen)
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
            cancelAllHideTimers()
            revealAll(animated: true)
            return
        }

        // Each screen hides on its own timer, so moving from one screen's bar to
        // another's lets the first slide away instead of waiting for the pointer to
        // leave every bar.
        for key in entries.keys {
            if isPointer(point, overBarOf: key) {
                cancelHideTimer(for: key)
                setRevealed(true, for: key, animated: true)
            } else if revealedKeys.contains(key) {
                scheduleHide(for: key)
            }
        }
    }

    /// A revealed bar stays up while the pointer is anywhere over it; a hidden one
    /// only reacts to the configurable strip along the screen edge.
    private func isPointer(_ point: NSPoint, overBarOf key: ScreenKey) -> Bool {
        guard let frame = entries[key]?.screen.frame else { return false }
        let zoneHeight = revealedKeys.contains(key)
            ? TaskbarSettings.shared.barHeight + 4
            : CGFloat(TaskbarSettings.shared.autoHideRevealZone)
        return NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: zoneHeight).contains(point)
    }

    private func scheduleHide(for key: ScreenKey) {
        guard hideTimers[key] == nil else { return }
        let delay = TaskbarSettings.shared.autoHideDelay
        if delay <= 0 {
            hideIfIdle(key)
            return
        }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideIfIdle(key) }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimers[key] = timer
    }

    private func hideIfIdle(_ key: ScreenKey) {
        hideTimers[key] = nil
        guard keepVisibleCount == 0,
              !isPointer(NSEvent.mouseLocation, overBarOf: key) else { return }
        setRevealed(false, for: key, animated: true)
    }

    private func cancelHideTimer(for key: ScreenKey) {
        hideTimers.removeValue(forKey: key)?.invalidate()
    }

    private func cancelAllHideTimers() {
        hideTimers.values.forEach { $0.invalidate() }
        hideTimers.removeAll()
    }

    private func revealAll(animated: Bool) {
        for key in entries.keys {
            setRevealed(true, for: key, animated: animated)
        }
    }

    private func setRevealed(_ revealed: Bool, for key: ScreenKey, animated: Bool) {
        guard let entry = entries[key] else { return }
        if revealed == revealedKeys.contains(key), animated { return }
        if revealed {
            revealedKeys.insert(key)
        } else {
            revealedKeys.remove(key)
        }

        let height = TaskbarSettings.shared.barHeight
        let screenFrame = entry.screen.frame
        let fades = hasScreen(below: screenFrame, barHeight: height)
        let hiddenY = fades ? screenFrame.minY : screenFrame.minY - (height - peekHeight)
        let frame = NSRect(
            x: screenFrame.minX,
            y: revealed ? screenFrame.minY : hiddenY,
            width: screenFrame.width,
            height: height
        )
        let alpha: CGFloat = revealed || !fades ? 1 : 0
        // A faded-out bar still sits over the bottom of the screen; let clicks
        // through to the windows beneath it. Reveal stays driven by the mouse
        // monitors, which don't depend on the panel receiving events.
        entry.panel.ignoresMouseEvents = alpha == 0
        // A preview placed against the bar's old position would be left floating.
        if entry.panel.frame != frame || entry.panel.alphaValue != alpha {
            WindowPreviewController.shared.barWillMove(entry.panel)
        }

        // Superseding a reveal mid-flight ends it; jumping straight to revealed
        // settles the bar here rather than in the completion handler.
        let interruptedReveal = revealsInFlight.removeValue(forKey: key) != nil
        if animated {
            let generation: Int? = revealed ? nextRevealGeneration() : nil
            revealsInFlight[key] = generation
            NSAnimationContext.runAnimationGroup({ context in
                // Reveal speed is the user's; hiding keeps the stock slide.
                let duration = fades ? fadeDuration : slideDuration
                context.duration = revealed ? min(duration, TaskbarSettings.shared.revealDuration) : duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                entry.panel.animator().setFrame(frame, display: true)
                entry.panel.animator().alphaValue = alpha
            }, completionHandler: { [weak self] in
                guard let generation else { return }
                // Animation completions run on the main thread.
                MainActor.assumeIsolated { self?.revealFinished(key, generation: generation) }
            })
        } else {
            entry.panel.setFrame(frame, display: true)
            entry.panel.alphaValue = alpha
            if revealed, interruptedReveal {
                WindowPreviewController.shared.barDidSettle(entry.panel)
            }
        }
    }

    private func nextRevealGeneration() -> Int {
        revealGeneration += 1
        return revealGeneration
    }

    private func revealFinished(_ key: ScreenKey, generation: Int) {
        guard revealsInFlight[key] == generation, let panel = entries[key]?.panel else { return }
        revealsInFlight[key] = nil
        WindowPreviewController.shared.barDidSettle(panel)
    }

    /// Parking the bar below its screen only hides it when nothing is there. With
    /// a display stacked underneath, the parked bar would draw across the top of
    /// that display instead, so those screens fade the bar out in place.
    private func hasScreen(below frame: NSRect, barHeight: CGFloat) -> Bool {
        let parked = NSRect(x: frame.minX, y: frame.minY - barHeight, width: frame.width, height: barHeight)
        return NSScreen.screens.contains { $0.frame != frame && $0.frame.intersects(parked) }
    }
}
