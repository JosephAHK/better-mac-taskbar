import Foundation
import AppKit
import ApplicationServices

final class WindowManager {
    static let shared = WindowManager()

    private(set) var windows: [WindowInfo] = []
    private var pollTimer: Timer?
    private var refreshDebounceWorkItem: DispatchWorkItem?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var axObservers: [pid_t: AXObserver] = [:]
    /// Last taskbar icon the user clicked — optimistic underline until the OS
    /// reports a different front window (manual click / Cmd-` / etc.).
    private(set) var lastActivatedWindowID: String?
    private var lastActivatedAt: Date?
    /// Brief window where taskbar click wins over still-stale front-window probes.
    private let activationGrace: TimeInterval = 1.2
    private var scriptedTitleCache: [String: (titles: [String], at: Date)] = [:]
    /// Keep AppleScript cache short so new Chrome windows appear quickly without AX.
    private let scriptedTitleCacheTTL: TimeInterval = 0.35
    /// Backup poll — AX observers handle most window create/close events instantly.
    private let pollInterval: TimeInterval = 0.35

    private init() {}

    func noteActivated(id: String) {
        lastActivatedWindowID = id
        lastActivatedAt = Date()
        // Optimistic underline update — don't wait for AppleScript/refresh.
        let updated = windows.map { win in
            WindowInfo(
                id: win.id,
                pid: win.pid,
                cgWindowID: win.cgWindowID,
                title: win.title,
                bundleID: win.bundleID,
                appName: win.appName,
                isMinimized: win.isMinimized,
                isOnScreen: win.isOnScreen,
                isActive: win.id == id,
                axElement: win.axElement
            )
        }
        if updated != windows {
            windows = updated
            NotificationCenter.default.post(name: .windowsUpdated, object: nil)
        }
    }

    private var isWithinActivationGrace: Bool {
        guard let at = lastActivatedAt else { return false }
        return Date().timeIntervalSince(at) < activationGrace
    }

    /// Prefer the live front window; keep a short grace after taskbar clicks so
    /// raise lag doesn't snap the underline back to the previous window.
    private func resolveActiveID(detectedFrontID: String?, candidates: [String]) -> String? {
        if isWithinActivationGrace,
           let last = lastActivatedWindowID,
           candidates.contains(last) {
            return last
        }
        if let front = detectedFrontID, candidates.contains(front) {
            if lastActivatedWindowID != front {
                lastActivatedWindowID = front
                lastActivatedAt = nil
            }
            return front
        }
        if let last = lastActivatedWindowID, candidates.contains(last) {
            return last
        }
        return detectedFrontID ?? candidates.first
    }

    /// Focus a specific window. Uses AX when available; otherwise AppleScript by
    /// window title (CG z-order indices do not track Chrome's real front window).
    func activateWindow(_ info: WindowInfo) {
        noteActivated(id: info.id)

        // Raise off the main thread so the blue underline can paint immediately.
        let payload = info
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.raiseWindow(payload)
            DispatchQueue.main.async {
                self?.refresh()
            }
        }
    }

    /// Win10 taskbar click: minimize if this window is already front and visible;
    /// otherwise restore / activate it.
    func activateOrMinimizeWindow(_ info: WindowInfo) {
        // Fast path from strip state — avoid synchronous AX probes on the click.
        let isTaskbarActive = info.isActive || lastActivatedWindowID == info.id
        let willMinimize = !info.isMinimized && isTaskbarActive
        if info.isMinimized {
            activateWindow(info)
        } else if willMinimize {
            minimizeWindow(info)
        } else {
            activateWindow(info)
        }
    }

    /// Minimize one window (does not hide the whole app).
    func minimizeWindow(_ info: WindowInfo) {
        if lastActivatedWindowID == info.id {
            lastActivatedWindowID = nil
            lastActivatedAt = nil
        }
        // Optimistic underline clear so the bar reacts immediately.
        let updated = windows.map { win in
            WindowInfo(
                id: win.id,
                pid: win.pid,
                cgWindowID: win.cgWindowID,
                title: win.title,
                bundleID: win.bundleID,
                appName: win.appName,
                isMinimized: win.id == info.id ? true : win.isMinimized,
                isOnScreen: win.id == info.id ? false : win.isOnScreen,
                isActive: false,
                axElement: win.axElement
            )
        }
        if updated != windows {
            windows = updated
            NotificationCenter.default.post(name: .windowsUpdated, object: nil)
        }

        let payload = info
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let axTrusted = AccessibilityService.isTrusted(prompt: false)
            let ax = AccessibilityService.resolveWindow(
                pid: payload.pid,
                title: payload.title,
                cached: payload.axElement
            )
            var minimized = false

            if let ax {
                AccessibilityService.minimize(ax)
                minimized = AccessibilityService.isMinimized(ax)
                if !minimized {
                    AccessibilityService.minimize(ax)
                    minimized = AccessibilityService.isMinimized(ax)
                }
            }

            // Never activate() while minimizing — that flashes the window to front
            // before it goes away (especially Spotify / Electron without AX).
            if !minimized && axTrusted {
                let scriptStatus = AccessibilityService.minimizeScriptedWindowStatus(
                    bundleID: payload.bundleID,
                    appName: payload.appName,
                    title: payload.title
                )
                minimized = scriptStatus.hasPrefix("ok")
            }

            // Hide is the reliable no-flash path without AX (and a good AX fallback).
            if !minimized {
                _ = NSRunningApplication(processIdentifier: payload.pid)?.hide()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self?.refresh()
            }
        }
    }

    /// Close one window without quitting the app. AX close button → AppleScript → ⌘W.
    func closeWindow(_ info: WindowInfo) {
        let payload = info
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let ax = AccessibilityService.resolveWindow(
                pid: payload.pid,
                title: payload.title,
                cached: payload.axElement
            )
            if let ax {
                AccessibilityService.close(ax, pid: payload.pid)
            } else if !payload.title.isEmpty {
                let ok = AccessibilityService.closeScriptedWindow(
                    bundleID: payload.bundleID,
                    appName: payload.appName,
                    title: payload.title
                )
                if !ok {
                    NSRunningApplication(processIdentifier: payload.pid)?
                        .activate(options: [.activateIgnoringOtherApps])
                    AccessibilityService.postCommandW()
                }
            } else {
                NSRunningApplication(processIdentifier: payload.pid)?
                    .activate(options: [.activateIgnoringOtherApps])
                AccessibilityService.postCommandW()
            }
            DispatchQueue.main.async {
                self?.refresh()
            }
        }
    }

    private func raiseWindow(_ info: WindowInfo) {
        // One raise path only — stacking AXRaise / activate makes windows crawl forward.
        let app = NSRunningApplication(processIdentifier: info.pid)
        let wasHidden = app?.isHidden ?? false
        app?.unhide()

        let axWindows = AccessibilityService.windows(for: info.pid)
        let liveMatch = resolveAXWindow(for: info, in: axWindows)

        if let ax = liveMatch {
            AccessibilityService.raise(ax, pid: info.pid)
            return
        }

        // Hidden apps (Spotify Cmd+H) often still report a CG frame with isMinimized=false
        // and an empty title — still need scripted deminiaturize / reopen, not bare activate.
        let needsRestore = wasHidden || info.isMinimized || !info.title.isEmpty
        if needsRestore {
            let ok = AccessibilityService.raiseScriptedWindow(
                bundleID: info.bundleID,
                appName: info.appName,
                title: info.title,
                pid: info.pid
            )
            if ok { return }
        }

        // Electron / Chromium apps: activate updates the menu bar but does not bring
        // the window forward when the app was hidden. Launch Services reopen does.
        let reopenBundles: Set<String> = [
            "com.google.Chrome",
            "com.google.Chrome.beta",
            "com.google.Chrome.canary",
            "com.apple.Safari",
            "company.thebrowser.Browser",
            "com.brave.Browser",
            "org.mozilla.firefox",
            "com.spotify.client",
            "com.tinyspeck.slackmacgap",
            "com.anthropic.claudefordesktop",
            "com.microsoft.VSCode",
            "com.todesktop.230313mzl4w4u92"
        ]
        if (wasHidden || info.isMinimized),
           let bundleID = info.bundleID,
           reopenBundles.contains(bundleID),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
            return
        }

        AccessibilityService.forceShowApp(pid: info.pid, bundleID: info.bundleID)
    }

    /// Resolve the live AX window for a taskbar entry. When restoring a minimized
    /// window, prefer a minimized match so we don't raise a visible sibling and
    /// incorrectly skip deminimize.
    private func resolveAXWindow(for info: WindowInfo, in axWindows: [AXUIElement]) -> AXUIElement? {
        let titled: [AXUIElement]
        if info.title.isEmpty {
            titled = []
        } else {
            titled = axWindows.filter { AccessibilityService.title(of: $0) == info.title }
        }

        // Prefer a live minimized title match even when the snapshot's
        // isMinimized flag is stale (refresh lag after yellow-button minimize).
        if let match = titled.first(where: { AccessibilityService.isMinimized($0) }) {
            return match
        }

        if info.isMinimized {
            let minimized = axWindows.filter { AccessibilityService.isMinimized($0) }
            if minimized.count == 1 { return minimized[0] }
            if let match = titled.first { return match }
            if let match = minimized.first { return match }
        }

        if let cached = info.axElement,
           axWindows.contains(where: { CFEqual($0, cached) }) {
            return cached
        }

        if let match = titled.first { return match }

        // Fall back to CG frame correlation when titles are blank/duplicated.
        if let cgID = info.cgWindowID,
           let entry = buildCGIndex().first(where: { $0.windowID == cgID && $0.pid == info.pid }) {
            let byFrame = axWindows.min(by: { a, b in
                let fa = AccessibilityService.frame(of: a) ?? .null
                let fb = AccessibilityService.frame(of: b) ?? .null
                return distance(fa, entry.bounds) < distance(fb, entry.bounds)
            })
            if let byFrame,
               let frame = AccessibilityService.frame(of: byFrame),
               distance(frame, entry.bounds) < 40 {
                return byFrame
            }
        }

        return info.axElement
    }

    private func cachedScriptedTitles(bundleID: String) -> [String] {
        if let cached = scriptedTitleCache[bundleID],
           Date().timeIntervalSince(cached.at) < scriptedTitleCacheTTL {
            return cached.titles
        }
        let titles = AccessibilityService.scriptedWindowTitles(bundleID: bundleID)
        scriptedTitleCache[bundleID] = (titles, Date())
        return titles
    }

    private func invalidateScriptedTitleCache() {
        scriptedTitleCache.removeAll(keepingCapacity: true)
    }

    /// Coalesce bursty AX/workspace events into one refresh.
    func scheduleRefresh(immediate: Bool = false) {
        refreshDebounceWorkItem?.cancel()
        if immediate {
            invalidateScriptedTitleCache()
            refresh()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.invalidateScriptedTitleCache()
            self?.refresh()
        }
        refreshDebounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    func start() {
        AppLog.info("WindowManager.start")
        stop()
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        if let timer = pollTimer {
            RunLoop.main.add(timer, forMode: .common)
        }

        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // App launch/terminate must re-wire AX observers immediately.
                let needsObserverSync =
                    name == NSWorkspace.didLaunchApplicationNotification
                    || name == NSWorkspace.didTerminateApplicationNotification
                self?.scheduleRefresh(immediate: needsObserverSync)
            }
            workspaceObservers.append(token)
        }
    }

    func stop() {
        AppLog.info("WindowManager.stop")
        refreshDebounceWorkItem?.cancel()
        refreshDebounceWorkItem = nil
        pollTimer?.invalidate()
        pollTimer = nil
        removeAllAXObservers()
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers {
            center.removeObserver(token)
        }
        workspaceObservers.removeAll()
    }

    func refresh() {
        let trusted = AccessibilityService.isTrusted(prompt: false)
        let enumerated: [WindowInfo]
        if trusted {
            syncAXObservers()
            enumerated = enumerateViaAccessibility()
        } else {
            removeAllAXObservers()
            enumerated = enumerateViaCGFallback()
        }
        let next = finalizeActiveFlags(stabilizeOrder(enumerated))

        if next != windows {
            windows = next
            NotificationCenter.default.post(name: .windowsUpdated, object: nil)
        }
    }

    /// After a taskbar click, keep that icon's blue underline stable even when
    /// frontmost probes still lag (or fail without Accessibility).
    private func finalizeActiveFlags(_ windows: [WindowInfo]) -> [WindowInfo] {
        let detectedActive = windows.first(where: \.isActive)?.id

        let activeID: String?
        if isWithinActivationGrace,
           let last = lastActivatedWindowID,
           windows.contains(where: { $0.id == last }) {
            activeID = last
        } else if let detected = detectedActive {
            if lastActivatedWindowID != detected {
                lastActivatedWindowID = detected
                lastActivatedAt = nil
            }
            activeID = detected
        } else if let last = lastActivatedWindowID,
                  windows.contains(where: { $0.id == last }) {
            // No reliable front-window signal — keep the taskbar selection.
            activeID = last
        } else {
            activeID = nil
        }

        guard windows.contains(where: { $0.isActive != ($0.id == activeID) }) else {
            return windows
        }
        return windows.map { win in
            WindowInfo(
                id: win.id,
                pid: win.pid,
                cgWindowID: win.cgWindowID,
                title: win.title,
                bundleID: win.bundleID,
                appName: win.appName,
                isMinimized: win.isMinimized,
                isOnScreen: win.isOnScreen,
                isActive: win.id == activeID,
                axElement: win.axElement
            )
        }
    }

    // MARK: - AX window event observers

    private func syncAXObservers() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let livePIDs = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != selfPID }
                .map(\.processIdentifier)
        )

        for pid in axObservers.keys where !livePIDs.contains(pid) {
            removeAXObserver(for: pid)
        }
        for pid in livePIDs where axObservers[pid] == nil {
            addAXObserver(for: pid)
        }
    }

    private func addAXObserver(for pid: pid_t) {
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let manager = Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async {
                manager.scheduleRefresh()
            }
        }

        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }

        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let notifications = [
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification
        ] as [CFString]

        for name in notifications {
            let result = AXObserverAddNotification(observer, app, name, refcon)
            // Some apps reject individual notifications; keep going for the rest.
            _ = result
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        axObservers[pid] = observer
    }

    private func removeAXObserver(for pid: pid_t) {
        guard let observer = axObservers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
    }

    private func removeAllAXObservers() {
        for pid in Array(axObservers.keys) {
            removeAXObserver(for: pid)
        }
    }

    /// Keep existing left-to-right positions; only append new windows / drop closed ones.
    /// Selecting a window must not reshuffle icons.
    ///
    /// IDs can flip between `app-{pid}` and `{pid}-{cgWindowID}` when Accessibility is
    /// off and CG intermittently omits a window (common for Electron apps like Claude).
    /// Match those as the same slot by pid (and title when an app has multiple windows).
    private func stabilizeOrder(_ next: [WindowInfo]) -> [WindowInfo] {
        var remaining = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
        var ordered: [WindowInfo] = []
        var idRemap: [String: String] = [:]

        for previous in windows {
            if let updated = remaining.removeValue(forKey: previous.id) {
                ordered.append(updated)
                continue
            }

            let candidates = remaining.values.filter { $0.pid == previous.pid }
            let match: WindowInfo?
            if candidates.count == 1 {
                match = candidates[0]
            } else if !previous.title.isEmpty {
                match = candidates.first { $0.title == previous.title }
            } else {
                match = nil
            }

            if let match {
                remaining.removeValue(forKey: match.id)
                ordered.append(match)
                if previous.id != match.id {
                    idRemap[previous.id] = match.id
                }
            }
        }

        if !idRemap.isEmpty {
            if let last = lastActivatedWindowID, let mapped = idRemap[last] {
                lastActivatedWindowID = mapped
            }
            remapTaskbarOrderKeys(idRemap)
        }

        let newcomers = remaining.values.sorted { a, b in
            if a.appName != b.appName {
                return a.appName.localizedCaseInsensitiveCompare(b.appName) == .orderedAscending
            }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
        ordered.append(contentsOf: newcomers)
        if let selected = lastActivatedWindowID, !ordered.contains(where: { $0.id == selected }) {
            lastActivatedWindowID = nil
            lastActivatedAt = nil
        }
        return ordered
    }

    /// Rewrite persisted strip order when a window's id changes but it's the same app slot.
    private func remapTaskbarOrderKeys(_ remap: [String: String]) {
        var order = TaskbarSettings.shared.taskbarOrder
        guard !order.isEmpty else { return }
        var changed = false
        for i in order.indices {
            if let newID = remap[order[i]] {
                order[i] = newID
                changed = true
            }
        }
        guard changed else { return }
        // Write without posting .taskbarOrderChanged — windowsUpdated already reloads the strip.
        UserDefaults.standard.set(order, forKey: "taskbarOrder")
    }

    func window(withID id: String) -> WindowInfo? {
        windows.first { $0.id == id }
    }

    // MARK: - Enumeration

    private func enumerateViaAccessibility() -> [WindowInfo] {
        let cgIndex = buildCGIndex()
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var usedIDs = Set<String>()
        var usedCGIDs = Set<CGWindowID>()
        // Defer isActive until we know each PID's live front window.
        var pending: [(info: WindowInfo, ax: AXUIElement)] = []

        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }

        for app in apps {
            let pid = app.processIdentifier
            // Skip our own process
            if pid == ProcessInfo.processInfo.processIdentifier { continue }

            let axWindows = AccessibilityService.windows(for: pid)
            for (index, ax) in axWindows.enumerated() {
                let title = AccessibilityService.title(of: ax)
                let minimized = AccessibilityService.isMinimized(ax)
                let frame = AccessibilityService.frame(of: ax)
                let matchedCG = matchCGWindow(
                    pid: pid,
                    title: title,
                    frame: frame,
                    index: cgIndex,
                    claimedIDs: usedCGIDs
                )
                let cgID = matchedCG?.windowID
                let onScreen = matchedCG?.isOnScreen ?? !minimized

                // Skip tiny / offscreen utility that slipped through.
                // Minimized windows can report tiny Dock frames — keep them.
                if let frame, frame.width < 80 || frame.height < 80, !minimized {
                    continue
                }

                let id: String
                if let cgID {
                    id = "\(pid)-\(cgID)"
                    usedCGIDs.insert(cgID)
                } else {
                    // Prefer AX identity so multiple same-app windows stay distinct
                    // even when CG titles are blank (no Screen Recording) or matching fails.
                    id = "\(pid)-ax-\(index)-\(title.hashValue)"
                }
                if usedIDs.contains(id) {
                    continue
                }
                usedIDs.insert(id)

                let info = WindowInfo(
                    id: id,
                    pid: pid,
                    cgWindowID: cgID,
                    title: title,
                    bundleID: app.bundleIdentifier,
                    appName: app.localizedName ?? app.bundleIdentifier ?? "App",
                    isMinimized: minimized,
                    isOnScreen: onScreen,
                    isActive: false,
                    axElement: ax
                )
                pending.append((info, ax))
            }
        }

        // Resolve which window is active using live AX focused/main window.
        var activeID: String?
        if let frontmostPID {
            let group = pending.filter { $0.info.pid == frontmostPID && !$0.info.isMinimized }
            let frontAX = AccessibilityService.frontWindow(for: frontmostPID)
            let detectedFrontID: String? = {
                guard let frontAX else {
                    return group.first(where: {
                        AccessibilityService.isFocused($0.ax) || AccessibilityService.isMain($0.ax)
                    })?.info.id
                }
                if let match = group.first(where: { CFEqual($0.ax, frontAX) }) {
                    return match.info.id
                }
                // Chrome sometimes returns a focused window that isn't in AXWindows yet.
                return group.first(where: {
                    AccessibilityService.isFocused($0.ax) || AccessibilityService.isMain($0.ax)
                })?.info.id
            }()
            activeID = resolveActiveID(
                detectedFrontID: detectedFrontID,
                candidates: group.map(\.info.id)
            )
        }

        return pending.map { entry in
            WindowInfo(
                id: entry.info.id,
                pid: entry.info.pid,
                cgWindowID: entry.info.cgWindowID,
                title: entry.info.title,
                bundleID: entry.info.bundleID,
                appName: entry.info.appName,
                isMinimized: entry.info.isMinimized,
                isOnScreen: entry.info.isOnScreen,
                isActive: entry.info.id == activeID,
                axElement: entry.info.axElement
            )
        }
    }

    private func enumerateViaCGFallback() -> [WindowInfo] {
        // Without Accessibility: prefer AppleScript window lists for scriptable apps
        // (Chrome). CG z-order does not track which Chrome window is front, so
        // index-based raise was cycling one icon and no-oping the other.
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != selfPID }

        var results: [WindowInfo] = []
        var scriptedPIDs = Set<pid_t>()

        for app in apps {
            let pid = app.processIdentifier
            guard let bundleID = app.bundleIdentifier else { continue }
            // Only browsers/apps whose AppleScript window list is trustworthy.
            // Calling this for every app every second is slow and prompts Automation.
            let scriptable: Set<String> = [
                "com.google.Chrome",
                "com.google.Chrome.beta",
                "com.google.Chrome.canary",
                "com.apple.Safari",
                "company.thebrowser.Browser",
                "com.brave.Browser",
                "org.mozilla.firefox"
            ]
            guard scriptable.contains(bundleID) else { continue }
            let titles = cachedScriptedTitles(bundleID: bundleID)
            guard titles.count >= 1 else { continue }

            scriptedPIDs.insert(pid)

            let ids = titles.map { "script-\(bundleID)-\($0)" }
            // AppleScript returns windows front-to-back — index 0 is the real front window.
            let detectedFrontID = ids.first
            let activeID = (pid == frontmostPID)
                ? resolveActiveID(detectedFrontID: detectedFrontID, candidates: ids)
                : nil

            for (index, title) in titles.enumerated() {
                let id = ids[index]
                results.append(WindowInfo(
                    id: id,
                    pid: pid,
                    cgWindowID: nil,
                    title: title,
                    bundleID: bundleID,
                    appName: app.localizedName ?? bundleID,
                    isMinimized: false,
                    isOnScreen: true,
                    isActive: id == activeID,
                    axElement: nil
                ))
            }
        }

        // CG fallback for apps that are not scriptable (or returned no windows).
        // Collect per-PID first, then resolve a single active window for the frontmost app.
        var cgSeenPID = Set<pid_t>()
        let appsByPID = Dictionary(uniqueKeysWithValues: apps.map { ($0.processIdentifier, $0) })
        var cgPending: [WindowInfo] = []
        var frontmostCGCandidates: [String] = []
        var frontmostCGFrontID: String?

        let cgIndex = buildCGIndex()
        // Electron (Claude) often exposes untitled offscreen buffers that omit
        // kCGWindowIsOnscreen. If this PID already has a known on-screen window,
        // ignore those unknown-onscreen surfaces so they don't become extra icons.
        let pidsWithKnownOnscreen = Set(
            cgIndex
                .filter {
                    $0.onScreenKnown
                        && $0.isOnScreen
                        && $0.bounds.width >= 200
                        && $0.bounds.height >= 200
                }
                .map(\.pid)
        )

        for entry in cgIndex {
            guard let app = appsByPID[entry.pid] else { continue }
            if scriptedPIDs.contains(entry.pid) { continue }
            // Electron (Claude, etc.) often omits kCGWindowIsOnscreen. Treat unknown as
            // visible when the frame looks like a real window; only skip known-offscreen.
            // If this PID already has a known on-screen window, ignore unknown-onscreen
            // surfaces (offscreen Electron buffers) so they don't become extra icons.
            if entry.onScreenKnown {
                guard entry.isOnScreen else { continue }
            } else if pidsWithKnownOnscreen.contains(entry.pid) {
                continue
            } else {
                guard entry.bounds.width >= 200, entry.bounds.height >= 200 else { continue }
            }
            guard entry.bounds.width >= 200, entry.bounds.height >= 200 else { continue }
            cgSeenPID.insert(entry.pid)
            let windowID = "\(entry.pid)-\(entry.windowID)"
            if entry.pid == frontmostPID {
                frontmostCGCandidates.append(windowID)
                // CG list is front-to-back; first on-screen window is best-effort front.
                if frontmostCGFrontID == nil {
                    frontmostCGFrontID = windowID
                }
            }
            cgPending.append(WindowInfo(
                id: windowID,
                pid: entry.pid,
                cgWindowID: entry.windowID,
                title: entry.title,
                bundleID: app.bundleIdentifier,
                appName: app.localizedName ?? app.bundleIdentifier ?? "App",
                // Cmd+H hidden apps still have CG frames — treat as restore targets.
                isMinimized: app.isHidden,
                isOnScreen: entry.onScreenKnown ? entry.isOnScreen : true,
                isActive: false,
                axElement: nil
            ))
        }

        let cgActiveID: String? = {
            guard frontmostPID != nil, !frontmostCGCandidates.isEmpty else { return nil }
            return resolveActiveID(
                detectedFrontID: frontmostCGFrontID,
                candidates: frontmostCGCandidates
            )
        }()

        for info in cgPending {
            results.append(WindowInfo(
                id: info.id,
                pid: info.pid,
                cgWindowID: info.cgWindowID,
                title: info.title,
                bundleID: info.bundleID,
                appName: info.appName,
                isMinimized: info.isMinimized,
                isOnScreen: info.isOnScreen,
                isActive: info.id == cgActiveID,
                axElement: nil
            ))
        }

        // Second pass: known-offscreen large windows (miniaturized) for apps we missed.
        for entry in buildCGIndex() {
            guard let app = appsByPID[entry.pid] else { continue }
            if scriptedPIDs.contains(entry.pid) || cgSeenPID.contains(entry.pid) { continue }
            guard entry.onScreenKnown, !entry.isOnScreen else { continue }
            guard entry.bounds.width >= 200, entry.bounds.height >= 200 else { continue }
            cgSeenPID.insert(entry.pid)
            results.append(WindowInfo(
                id: "app-\(entry.pid)",
                pid: entry.pid,
                cgWindowID: entry.windowID,
                title: entry.title,
                bundleID: app.bundleIdentifier,
                appName: app.localizedName ?? app.bundleIdentifier ?? "App",
                isMinimized: true,
                isOnScreen: false,
                isActive: false,
                axElement: nil
            ))
        }

        // Prefer stable app-{pid} ids for single-window apps. CG window IDs appear and
        // disappear across polls (Electron), which used to reshuffle the taskbar on click.
        // Do NOT collapse multi-window untitled Electron apps (Cursor, etc.): CG often
        // omits titles, and real windows were being merged into one icon. Size filters
        // above already drop tiny helper/panel surfaces.
        let counts = Dictionary(grouping: results, by: \.pid).mapValues(\.count)
        results = results.map { info in
            if counts[info.pid] == 1 {
                guard !info.id.hasPrefix("script-") else { return info }
                let stableID = "app-\(info.pid)"
                guard info.id != stableID else { return info }
                return WindowInfo(
                    id: stableID,
                    pid: info.pid,
                    cgWindowID: info.cgWindowID,
                    title: info.title,
                    bundleID: info.bundleID,
                    appName: info.appName,
                    isMinimized: info.isMinimized,
                    isOnScreen: info.isOnScreen,
                    isActive: info.isActive,
                    axElement: nil
                )
            }
            return info
        }

        // Do NOT invent ghost icons for running apps with zero windows (Chrome stays
        // alive in the background with no windows). Miniaturized windows are covered
        // by the offscreen CG pass above; pinned apps still show via orderedDisplayItems.

        return results
    }

    // MARK: - CG window matching

    private struct CGEntry {
        let windowID: CGWindowID
        let pid: pid_t
        let title: String
        let bounds: CGRect
        let isOnScreen: Bool
        /// False when CG omits kCGWindowIsOnscreen (common for offscreen buffers).
        let onScreenKnown: Bool
    }

    private func buildCGIndex() -> [CGEntry] {
        // Include off-screen windows so minimized Chrome windows can still match.
        guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var entries: [CGEntry] = []
        for dict in info {
            let layer = dict[kCGWindowLayer as String] as? Int ?? -1
            guard layer == 0 else { continue }
            let alpha = dict[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0.05 else { continue }
            guard let pid = dict[kCGWindowOwnerPID as String] as? pid_t else { continue }
            guard let number = dict[kCGWindowNumber as String] as? CGWindowID else { continue }
            let title = dict[kCGWindowName as String] as? String ?? ""
            let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            guard bounds.width >= 80, bounds.height >= 80 else { continue }
            let onScreenFlag = dict[kCGWindowIsOnscreen as String] as? Bool
            entries.append(CGEntry(
                windowID: number,
                pid: pid,
                title: title,
                bounds: bounds,
                isOnScreen: onScreenFlag ?? false,
                onScreenKnown: onScreenFlag != nil
            ))
        }
        return entries
    }

    private func matchCGWindow(
        pid: pid_t,
        title: String,
        frame: CGRect?,
        index: [CGEntry],
        claimedIDs: Set<CGWindowID>
    ) -> CGEntry? {
        let candidates = index.filter { $0.pid == pid && !claimedIDs.contains($0.windowID) }
        if candidates.isEmpty { return nil }

        if !title.isEmpty {
            if let exact = candidates.first(where: { $0.title == title }) {
                return exact
            }
        }

        if let frame {
            // AX uses top-left global coords similar to CG for position attribute on modern macOS
            let match = candidates.min(by: { a, b in
                distance(a.bounds, frame) < distance(b.bounds, frame)
            })
            if let match, distance(match.bounds, frame) < 40 {
                return match
            }
        }

        // Only claim the lone remaining CG window for this PID — never reuse
        // candidates.first across multiple AX windows (that collapsed Chrome).
        if candidates.count == 1 {
            return candidates[0]
        }
        return nil
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = a.origin.x - b.origin.x
        let dy = a.origin.y - b.origin.y
        let dw = a.width - b.width
        let dh = a.height - b.height
        return abs(dx) + abs(dy) + abs(dw) + abs(dh)
    }
}
