import Foundation
import AppKit
import ApplicationServices
import os

/// Window state and enumeration are main-thread only. Window actions (raise, minimize,
/// close) block on AX / AppleScript round-trips, so they run on `actionQueue`; the
/// helpers they use are `nonisolated` and touch no mutable state.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private(set) var windows: [WindowInfo] = []
    private var pollTimer: Timer?
    private var refreshDebounceWorkItem: DispatchWorkItem?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var axObservers: [pid_t: AXObserver] = [:]
    /// Apps whose observer could not register a single notification — typical right at
    /// launch, before the app answers AX — and when to try again.
    private var axObserverRetries: [pid_t: (retryAt: Date, delay: TimeInterval)] = [:]
    /// Windows already registered for kAXUIElementDestroyedNotification, per app.
    private var destructionObservedWindows: [pid_t: Set<AXUIElement>] = [:]
    /// Apps that stopped answering AX within the messaging timeout. Each costs a full
    /// timeout per call on the main thread, so they are skipped until `retryAt` and
    /// their last-known windows are kept on the taskbar meanwhile.
    private var unresponsiveApps: [pid_t: (retryAt: Date, backoff: TimeInterval)] = [:]
    private let unresponsiveInitialBackoff: TimeInterval = 2
    private let unresponsiveMaxBackoff: TimeInterval = 10
    /// A responsive app enumerates in milliseconds. Past this, the app stalled partway
    /// and attributes read after the stall came back empty.
    private let enumerationBudgetPerApp: CFTimeInterval = 0.5
    /// Raise / minimize / close run one at a time, in click order. Concurrent raises
    /// each ran a verify-and-re-raise loop, so clicking A then B could end on A.
    nonisolated private let actionQueue = DispatchQueue(label: "BetterMacTaskbar.windowActions", qos: .userInteractive)
    /// Bumped by every raise and minimize. A raise that is no longer current stops
    /// re-raising its window instead of fighting the newer action.
    nonisolated private let actionGeneration = OSAllocatedUnfairLock(initialState: 0)
    /// Last taskbar icon the user clicked — optimistic underline until the OS
    /// reports a different front window (manual click / Cmd-` / etc.).
    private(set) var lastActivatedWindowID: String?
    private var lastActivatedAt: Date?
    /// Brief window where taskbar click wins over still-stale front-window probes.
    private let activationGrace: TimeInterval = 1.2
    /// Skip in-process AppleScript title polls after a click — NSAppleScript activates
    /// this accessory app and flashes focus back to the previous window.
    private var suppressScriptedTitlesUntil: Date?
    private var scriptedTitleCache: [String: (titles: [String], at: Date)] = [:]
    private var scriptedTitleFetchesInFlight: Set<String> = []
    /// Titles are fetched off main and served from cache meanwhile. Shorter than this
    /// scripted the browser on nearly every poll; workspace events still force an early
    /// refetch, so new windows rarely wait the full TTL.
    private let scriptedTitleCacheTTL: TimeInterval = 2
    /// Backup poll — AX observers handle most window create/close events instantly.
    private let pollInterval: TimeInterval = 0.35

    private init() {}

    private var shouldSuppressScriptedTitles: Bool {
        guard let until = suppressScriptedTitlesUntil else { return false }
        return Date() < until
    }

    /// If in-process AppleScript left *us* frontmost, push focus back to the target.
    nonisolated private func reclaimFrontIfStolen(for info: WindowInfo) {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == selfPID else { return }
        AccessibilityService.forceShowApp(pid: info.pid, bundleID: info.bundleID)
    }

    func noteActivated(id: String) {
        lastActivatedWindowID = id
        lastActivatedAt = Date()
        // Optimistic underline update — don't wait for AppleScript/refresh.
        let updated = windows.map { $0.with(isActive: $0.id == id) }
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
        WindowDiagnostics.noteClick(info)
        noteActivated(id: info.id)
        // Block Chrome title AppleScript during grace — it activates this app and flashes.
        suppressScriptedTitlesUntil = Date().addingTimeInterval(activationGrace + 0.4)

        // Raise off the main thread so the blue underline can paint immediately.
        let generation = beginWindowAction()
        actionQueue.async { [weak self] in
            // A later click already queued behind this one decides what ends up in front.
            guard let self, self.isCurrentWindowAction(generation) else { return }
            self.raiseWindow(info, generation: generation)
            self.reclaimFrontIfStolen(for: info)
            DispatchQueue.main.async { [weak self] in
                self?.refresh()
                self?.reclaimFrontIfStolen(for: info)
            }
            // Deminimize animation finishes after the immediate refresh, so that
            // snapshot can still carry the old isMinimized flag. Re-read once the
            // animation is done, otherwise the next click reads stale state.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                self?.refresh()
            }
        }
    }

    private func beginWindowAction() -> Int {
        actionGeneration.withLock { generation in
            generation += 1
            return generation
        }
    }

    nonisolated private func isCurrentWindowAction(_ generation: Int) -> Bool {
        actionGeneration.withLock { $0 } == generation
    }

    /// This app's layer-0, real-size windows on the active Space, front to back. One
    /// window-server snapshot shared by the presence and ordering checks below; nil
    /// when CG is unavailable.
    nonisolated private func onScreenWindows(pid: pid_t) -> [[String: Any]]? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        return list.filter { dict in
            guard (dict[kCGWindowOwnerPID as String] as? pid_t) == pid else { return false }
            guard (dict[kCGWindowLayer as String] as? Int ?? -1) == 0 else { return false }
            let alpha = dict[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0.05 else { return false }
            let bounds = Self.bounds(of: dict)
            return bounds.width >= 200 && bounds.height >= 200
        }
    }

    /// Whether *this specific window* is displayed on the currently active Space.
    ///
    /// `.optionOnScreenOnly` omits minimized windows entirely, which makes it the
    /// authoritative "is it actually on screen right now" test — the yellow-button
    /// case AX can still be lying about. It is also Space-scoped, unlike
    /// countRealWindows(), which deliberately spans all Spaces.
    ///
    /// Matching on cgWindowID (not just PID) matters: a multi-window app with one
    /// window minimized and another visible would otherwise report "present" and the
    /// click would minimize the visible sibling instead of restoring the one clicked.
    nonisolated private func isWindowOnActiveSpace(_ info: WindowInfo, among onScreen: [[String: Any]]) -> Bool {
        // Exact window match when the snapshot carries a CG id.
        if let cgID = info.cgWindowID {
            return onScreen.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == cgID }
        }
        // Title match next — distinguishes siblings when no CG id is recorded.
        if !info.title.isEmpty {
            let byTitle = onScreen.contains { ($0[kCGWindowName as String] as? String) == info.title }
            if byTitle { return true }
            // Titles are often unavailable without Screen Recording permission; only
            // trust a title miss when some window of this app did report a title.
            let anyTitled = onScreen.contains { !(($0[kCGWindowName as String] as? String) ?? "").isEmpty }
            if anyTitled { return false }
        }
        // Fall back to app-level presence.
        return !onScreen.isEmpty
    }

    /// Whether this window is the front-most of its own app's windows.
    ///
    /// `isWindowOnActiveSpace` only answers "is it visible", which is always true for a
    /// sibling sitting behind another window of the same app — clicking Chrome window B
    /// while A is in front would look satisfied and never get reordered. CG returns
    /// windows front-to-back, so the clicked window must be the app's first entry.
    ///
    /// Returns true when the app has at most one real window, or when we cannot identify
    /// the window well enough to judge — never block a raise on a guess.
    nonisolated private func isWindowFrontOfSiblings(_ info: WindowInfo, among onScreen: [[String: Any]]) -> Bool {
        // CG z-order spans every display, so a sibling "in front" on another monitor
        // would trigger a pointless re-raise. Compare only windows on the clicked
        // window's display, when the clicked window can be located.
        let target = info.cgWindowID.flatMap { cgID in
            onScreen.first { ($0[kCGWindowNumber as String] as? CGWindowID) == cgID }
        } ?? (info.title.isEmpty ? nil : onScreen.first {
            ($0[kCGWindowName as String] as? String) == info.title
        })
        var siblings = onScreen
        if let target, let display = Self.displayBounds(containing: Self.bounds(of: target)) {
            siblings = onScreen.filter { Self.bounds(of: $0).intersects(display) }
        }

        // Nothing to be in front of.
        guard siblings.count > 1, let front = siblings.first else { return true }

        // CG id is authoritative when the snapshot carries one.
        if let cgID = info.cgWindowID {
            return (front[kCGWindowNumber as String] as? CGWindowID) == cgID
        }
        // Titles need Screen Recording to be populated; only trust them when present.
        if !info.title.isEmpty,
           let frontTitle = front[kCGWindowName as String] as? String,
           !frontTitle.isEmpty {
            return frontTitle == info.title
        }
        // Can't tell which sibling was clicked — let the raise proceed.
        return true
    }

    /// Bounds of the display under the centre of a CG-coordinate rect. CGDisplayBounds
    /// shares CGWindow's top-left global space, and unlike NSScreen is safe off main.
    nonisolated private static func displayBounds(containing rect: CGRect) -> CGRect? {
        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(CGPoint(x: rect.midX, y: rect.midY), 1, &displayID, &count) == .success,
              count > 0 else { return nil }
        return CGDisplayBounds(displayID)
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

        // Supersedes an in-flight raise, whose verify loop would otherwise restore the
        // window right after this minimizes it.
        _ = beginWindowAction()
        actionQueue.async { [weak self] in
            guard let self else { return }
            let axTrusted = AccessibilityService.isTrusted(prompt: false)
            let ax = self.resolveTargetWindow(for: info, in: AccessibilityService.windows(for: info.pid))
            let fullScreen = ax.map(AccessibilityService.isFullScreen) ?? false
            var minimized = false

            if let ax {
                if fullScreen {
                    minimized = AccessibilityService.minimizeLeavingFullScreen(ax)
                } else {
                    AccessibilityService.minimize(ax)
                    minimized = AccessibilityService.isMinimized(ax)
                    if !minimized {
                        AccessibilityService.minimize(ax)
                        minimized = AccessibilityService.isMinimized(ax)
                    }
                }
            }

            // Never activate() while minimizing — that flashes the window to front
            // before it goes away (especially Spotify / Electron without AX).
            if !minimized && axTrusted {
                let scriptStatus = AccessibilityService.minimizeScriptedWindowStatus(
                    bundleID: info.bundleID,
                    appName: info.appName,
                    title: info.title
                )
                minimized = scriptStatus.hasPrefix("ok")
            }

            // Hide is the reliable no-flash path without AX (and a good AX fallback).
            // Not for a full-screen window: hiding takes every other window of the app
            // with it, which is worse than leaving the one window up.
            if !minimized {
                if fullScreen {
                    AppLog.warn("minimize failed for full-screen window; app left visible", [
                        "app": info.appName,
                        "pid": Int(info.pid)
                    ])
                } else {
                    _ = NSRunningApplication(processIdentifier: info.pid)?.hide()
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.refresh()
            }
        }
    }

    /// Close one window without quitting the app. AX close button → AppleScript → ⌘W.
    func closeWindow(_ info: WindowInfo) {
        actionQueue.async { [weak self] in
            guard let self else { return }
            let axWindows = AccessibilityService.windows(for: info.pid)
            if let ax = self.resolveTargetWindow(for: info, in: axWindows) {
                AccessibilityService.close(ax, pid: info.pid)
            } else if !AccessibilityService.closeScriptedWindow(
                bundleID: info.bundleID,
                appName: info.appName,
                title: info.title
            ) {
                if axWindows.isEmpty {
                    // The app publishes no AX windows (or AX is off), so its front
                    // window is the only handle left.
                    AccessibilityService.closeFrontWindowViaCommandW(pid: info.pid)
                } else {
                    // AX lists windows but none is this one. Cmd+W would close
                    // whichever happens to be in front — a different window.
                    AppLog.warn("close skipped: window not found", [
                        "app": info.appName,
                        "pid": Int(info.pid),
                        "cgWindowID": info.cgWindowID.map(String.init) ?? "none"
                    ])
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.refresh()
            }
        }
    }

    /// Same Launch Services path as right-click → New window. More reliable than
    /// `NSRunningApplication.activate` for Electron / Chromium (menu bar updates,
    /// window stays behind).
    nonisolated private static let launchServicesForegroundBundles: Set<String> = [
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

    nonisolated private func ensureFrontmostViaLaunchServices(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
    }

    nonisolated private func raiseWindow(_ info: WindowInfo, generation: Int) {
        // AX first so the clicked window (not a sibling) is deminimized / made main.
        // Then Launch Services when needed — bare activate often only flips the menu bar.
        let app = NSRunningApplication(processIdentifier: info.pid)
        let wasHidden = app?.isHidden ?? false
        app?.unhide()

        let axWindows = AccessibilityService.windows(for: info.pid)
        let liveMatch = resolveAXWindow(for: info, in: axWindows)

        var axRestored = false
        if let ax = liveMatch {
            AccessibilityService.raise(ax, pid: info.pid)
            // raise() retries deminimize, but it can still lose (Chrome, Electron,
            // sandboxed apps). Only count this as a restore if the window actually
            // came back — otherwise fall through to the scripted path below so the
            // first click succeeds instead of needing a second one.
            axRestored = !AccessibilityService.isMinimized(ax)
            if !axRestored {
                _ = AccessibilityService.raiseScriptedWindow(
                    bundleID: info.bundleID,
                    appName: info.appName,
                    title: info.title,
                    pid: info.pid
                )
                axRestored = !AccessibilityService.isMinimized(ax)
            }
        } else {
            // Hidden apps (Spotify Cmd+H) often still report a CG frame with isMinimized=false
            // and an empty title — still need scripted deminiaturize / reopen, not bare activate.
            // Do NOT AppleScript-activate visible Electron apps — NSAppleScript runs in-process
            // and makes Better Mac Taskbar frontmost (focus flash). Use Launch Services / forceShow below.
            let needsRestore = wasHidden || info.isMinimized || !info.title.isEmpty
            if needsRestore {
                _ = AccessibilityService.raiseScriptedWindow(
                    bundleID: info.bundleID,
                    appName: info.appName,
                    title: info.title,
                    pid: info.pid
                )
            }
        }

        guard let bundleID = info.bundleID else {
            WindowDiagnostics.noteRaiseResult(
                info,
                axResolved: liveMatch != nil,
                axRestored: axRestored,
                realWindows: countRealWindows(pid: info.pid),
                path: "forceShowApp/noBundleID"
            )
            AccessibilityService.forceShowApp(pid: info.pid, bundleID: nil)
            return
        }

        // Prefer frontmost PID over isActive — Electron apps often report isActive
        // while another app is still frontmostApplication.
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let stillNotFront = frontPID != info.pid
        let inLSList = Self.launchServicesForegroundBundles.contains(bundleID)
        let realWindows = countRealWindows(pid: info.pid)

        // Without an AX raise, `activate()` often only flips the menu bar (Calendar,
        // Mail, Notes, etc.) while windows stay hidden/unordered. Reopen via Launch
        // Services whenever the app has no real window at all, or was hidden/minimized.
        // Skip reopen when a window already exists — avoids spawning extras in Electron.
        let needsLSReopen = !axRestored
            && (wasHidden || info.isMinimized || realWindows == 0)

        // A click that resolves no AX window and finds no real window is the signature
        // of a ghost button: nothing below can possibly bring anything forward. Logged
        // as WARN by noteRaiseResult so it stands out from ordinary raises.
        WindowDiagnostics.noteRaiseResult(
            info,
            axResolved: liveMatch != nil,
            axRestored: axRestored,
            realWindows: realWindows,
            path: needsLSReopen ? "launchServicesReopen"
                : stillNotFront ? "activate" : "alreadyFront"
        )

        if needsLSReopen {
            ensureFrontmostViaLaunchServices(bundleID: bundleID)
        } else if stillNotFront {
            if inLSList && (wasHidden || info.isMinimized) {
                ensureFrontmostViaLaunchServices(bundleID: bundleID)
            } else {
                AccessibilityService.forceShowApp(pid: info.pid, bundleID: bundleID)
                // activate can succeed (menu bar changes) without ordering any window front.
                if countRealWindows(pid: info.pid) == 0 {
                    ensureFrontmostViaLaunchServices(bundleID: bundleID)
                }
            }
        }

        // Everything above only ever establishes that the *app* is frontmost. That is
        // not the same as the clicked *window* being visible: activate() flips the menu
        // bar and can leave the window behind other apps' windows, or behind a sibling
        // of its own. When the app was already frontmost (stillNotFront == false) the
        // branches above do nothing at all, so the click appears to have no effect.
        // Verify the actual window and re-raise if it did not come forward.
        ensureWindowOrderedFront(info, generation: generation)
    }

    /// Confirm the clicked window is really on screen *and* in front of its siblings;
    /// re-raise if not. Runs on the background action queue, so short sleeps are safe.
    nonisolated private func ensureWindowOrderedFront(_ info: WindowInfo, generation: Int) {
        for attempt in 0..<3 {
            // Give the WindowServer time to reflect the activate/raise before judging.
            Thread.sleep(forTimeInterval: attempt == 0 ? 0.08 : 0.12)
            guard isCurrentWindowAction(generation) else { return }
            // Can't see the window server — don't re-raise on a guess.
            guard let onScreen = onScreenWindows(pid: info.pid) else { return }
            // Presence alone is not enough: with two Chrome windows the clicked one is
            // already on screen but behind its sibling, so a presence-only check would
            // return here and skip the AXRaise that actually reorders it.
            if isWindowOnActiveSpace(info, among: onScreen)
                && isWindowFrontOfSiblings(info, among: onScreen) { return }

            let axWindows = AccessibilityService.windows(for: info.pid)
            if let ax = resolveAXWindow(for: info, in: axWindows) {
                AccessibilityService.deminimize(ax)
                AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(ax, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
            } else if attempt > 0 {
                // AX can't see it — last resort is the scripted AXRaise by title.
                _ = AccessibilityService.raiseScriptedWindow(
                    bundleID: info.bundleID,
                    appName: info.appName,
                    title: info.title,
                    pid: info.pid
                )
            }
            // Front-window-only — plain activate stacks every sibling to positions 1…N.
            _ = AccessibilityService.activateFrontWindowOnly(pid: info.pid)
        }
    }

    /// Layer-0 windows large enough to be a real app window, on any Space.
    /// Deliberately not `.optionOnScreenOnly` — that flag only reports windows on
    /// the *currently active* Space, so a Chrome/Electron window parked on another
    /// Space would otherwise read as "no window" and trigger a needless LS reopen.
    nonisolated private func countRealWindows(pid: pid_t) -> Int {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return 0
        }
        return info.filter { dict in
            guard (dict[kCGWindowOwnerPID as String] as? pid_t) == pid else { return false }
            let layer = dict[kCGWindowLayer as String] as? Int ?? -1
            guard layer == 0 else { return false }
            let alpha = dict[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0.05 else { return false }
            let bounds = dict[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let w = bounds["Width"] ?? 0
            let h = bounds["Height"] ?? 0
            return w >= 200 && h >= 200
        }.count
    }

    /// Resolve the live AX window for a taskbar entry. When restoring a minimized
    /// window, prefer a minimized match so we don't raise a visible sibling and
    /// incorrectly skip deminimize.
    nonisolated private func resolveAXWindow(for info: WindowInfo, in axWindows: [AXUIElement]) -> AXUIElement? {
        if let exact = axWindow(withID: info.cgWindowID, in: axWindows) {
            return exact
        }

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
        // Note: a stale cached axElement is deliberately NOT used as a last resort —
        // no live match is reported as nil. Returning the stale element would make
        // raiseWindow() believe it has a real window and skip the scripted /
        // Launch Services restore — the first click then does nothing and the
        // user has to click again.
        return axWindowMatchingCGFrame(of: info, in: axWindows)
    }

    /// Live AX window for close / minimize. Unlike `resolveAXWindow`, never settles for
    /// a plausible candidate (first title match, first window): acting on the wrong
    /// window is destructive, so anything short of a positive identification is nil.
    nonisolated private func resolveTargetWindow(for info: WindowInfo, in axWindows: [AXUIElement]) -> AXUIElement? {
        if let cached = info.axElement,
           axWindows.contains(where: { CFEqual($0, cached) }) {
            return cached
        }
        if let exact = axWindow(withID: info.cgWindowID, in: axWindows) {
            return exact
        }
        if !info.title.isEmpty {
            let titled = axWindows.filter { AccessibilityService.title(of: $0) == info.title }
            if titled.count == 1 { return titled[0] }
        }
        return axWindowMatchingCGFrame(of: info, in: axWindows)
    }

    nonisolated private func axWindow(withID cgWindowID: CGWindowID?, in axWindows: [AXUIElement]) -> AXUIElement? {
        guard let cgWindowID else { return nil }
        return axWindows.first { AccessibilityService.windowID(of: $0) == cgWindowID }
    }

    /// The AX window sitting where the entry's CG window is. For apps where
    /// `_AXUIElementGetWindow` fails, this is the only link back from a CG id.
    nonisolated private func axWindowMatchingCGFrame(of info: WindowInfo, in axWindows: [AXUIElement]) -> AXUIElement? {
        guard let cgID = info.cgWindowID,
              let entry = buildCGIndex().first(where: { $0.windowID == cgID && $0.pid == info.pid }) else {
            return nil
        }
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
        return nil
    }

    /// Cached titles, never a live script: a stale entry is refetched in the background
    /// and the result lands on a later refresh.
    private func cachedScriptedTitles(bundleID: String) -> [String] {
        let cached = scriptedTitleCache[bundleID]
        let isFresh = cached.map { Date().timeIntervalSince($0.at) < scriptedTitleCacheTTL } ?? false
        if !isFresh && !shouldSuppressScriptedTitles {
            fetchScriptedTitles(bundleID: bundleID)
        }
        return cached?.titles ?? []
    }

    private func fetchScriptedTitles(bundleID: String) {
        guard scriptedTitleFetchesInFlight.insert(bundleID).inserted else { return }
        AccessibilityService.fetchScriptedWindowTitles(bundleID: bundleID) { [weak self] titles in
            guard let self else { return }
            self.scriptedTitleFetchesInFlight.remove(bundleID)
            let previous = self.scriptedTitleCache[bundleID]?.titles
            self.scriptedTitleCache[bundleID] = (titles, Date())
            // Plain refresh, not scheduleRefresh — that invalidates the cache and
            // would start the next fetch straight away.
            if titles != previous {
                self.refresh()
            }
        }
    }

    /// Mark titles stale so the next refresh refetches them, but keep serving them
    /// until the fetch lands — dropping them blinks the browser's buttons out.
    private func invalidateScriptedTitleCache() {
        for bundleID in scriptedTitleCache.keys {
            scriptedTitleCache[bundleID]?.at = .distantPast
        }
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
            // Scheduled on the main run loop below.
            MainActor.assumeIsolated { self?.refresh() }
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
                MainActor.assumeIsolated { self?.scheduleRefresh(immediate: needsObserverSync) }
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
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != selfPID }
        let trusted = AccessibilityService.isTrusted(prompt: false)
        let enumerated: [WindowInfo]
        if trusted {
            let livePIDs = Set(apps.map(\.processIdentifier))
            unresponsiveApps = unresponsiveApps.filter { livePIDs.contains($0.key) }
            syncAXObservers(livePIDs: livePIDs)
            enumerated = enumerateViaAccessibility(apps: apps)
        } else {
            removeAllAXObservers()
            enumerated = enumerateViaCGFallback(apps: apps)
        }
        let next = finalizeActiveFlags(stabilizeOrder(enumerated))

        if next != windows {
            windows = next
            WindowDiagnostics.noteWindowSet(next)
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
        return windows.map { $0.with(isActive: $0.id == activeID) }
    }

    // MARK: - Unresponsive apps

    private func isBackingOff(_ pid: pid_t) -> Bool {
        guard let entry = unresponsiveApps[pid] else { return false }
        return Date() < entry.retryAt
    }

    /// Logged on the transition only — a hung app is retried every few seconds.
    private func noteUnresponsive(_ pid: pid_t, appName: String) {
        let previous = unresponsiveApps[pid]
        let backoff = previous.map { min($0.backoff * 2, unresponsiveMaxBackoff) } ?? unresponsiveInitialBackoff
        unresponsiveApps[pid] = (Date().addingTimeInterval(backoff), backoff)
        if previous == nil {
            AppLog.warn("app not answering accessibility; keeping last-known windows", [
                "app": appName,
                "pid": Int(pid)
            ])
        }
    }

    private func noteResponsive(_ pid: pid_t, appName: String) {
        guard unresponsiveApps.removeValue(forKey: pid) != nil else { return }
        AppLog.info("app answering accessibility again", ["app": appName, "pid": Int(pid)])
    }

    // MARK: - AX window event observers

    private func syncAXObservers(livePIDs: Set<pid_t>) {
        for pid in axObservers.keys where !livePIDs.contains(pid) {
            removeAXObserver(for: pid)
        }
        axObserverRetries = axObserverRetries.filter { livePIDs.contains($0.key) }
        let now = Date()
        for pid in livePIDs where axObservers[pid] == nil && !isBackingOff(pid) {
            if let retry = axObserverRetries[pid], now < retry.retryAt { continue }
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

        let app = AccessibilityService.applicationElement(for: pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Window destruction is registered per window — see observeDestruction(of:pid:).
        let notifications = [
            kAXWindowCreatedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification
        ] as [CFString]

        // Some apps reject individual notifications; keep going for the rest.
        let registered = notifications.filter { name in
            AXObserverAddNotification(observer, app, name, refcon) == .success
        }.count
        // Zero registrations is typical right after launch (cannotComplete until the
        // app answers AX). Keeping that observer would block every later attempt and
        // leave the app on the slow poll for good; drop it and retry with backoff.
        guard registered > 0 else {
            let delay = axObserverRetries[pid].map { min($0.delay * 2, 8) } ?? 0.5
            axObserverRetries[pid] = (Date().addingTimeInterval(delay), delay)
            return
        }
        axObserverRetries[pid] = nil

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        axObservers[pid] = observer
    }

    /// kAXUIElementDestroyedNotification only fires on the element it was registered
    /// on, so registering it on the app element never reported a closed window.
    /// Register each window as enumeration first sees it; forget windows that left.
    private func observeDestruction(of axWindows: [AXUIElement], pid: pid_t) {
        guard let observer = axObservers[pid] else { return }
        let current = Set(axWindows)
        var observed = destructionObservedWindows[pid] ?? []
        for window in observed.subtracting(current) {
            // Fails harmlessly for windows that are already gone.
            AXObserverRemoveNotification(observer, window, kAXUIElementDestroyedNotification as CFString)
            observed.remove(window)
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for window in current.subtracting(observed) {
            let result = AXObserverAddNotification(
                observer,
                window,
                kAXUIElementDestroyedNotification as CFString,
                refcon
            )
            if result == .success || result == .notificationAlreadyRegistered {
                observed.insert(window)
            }
        }
        destructionObservedWindows[pid] = observed
    }

    private func removeAXObserver(for pid: pid_t) {
        destructionObservedWindows[pid] = nil
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
        axObserverRetries.removeAll()
    }

    /// Keep existing left-to-right positions; only append new windows / drop closed ones.
    /// Selecting a window must not reshuffle icons.
    ///
    /// IDs can flip between `app-{pid}` and `{pid}-{cgWindowID}` when Accessibility is
    /// off and CG intermittently omits a window (common for Electron apps like Claude).
    /// Match those as the same slot by pid (and title when an app has multiple windows).
    private func stabilizeOrder(_ next: [WindowInfo]) -> [WindowInfo] {
        // Never use Dictionary(uniqueKeysWithValues:) — duplicate ids (e.g. two Chrome
        // windows with the same title) trap with EXC_BREAKPOINT and kill the process.
        var remaining = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { first, second in
            AppLog.error("duplicate window id dropped", [
                "id": first.id,
                "pid": first.pid,
                "keptTitle": first.title,
                "droppedTitle": second.title
            ])
            return first
        })
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

    private func enumerateViaAccessibility(apps: [NSRunningApplication]) -> [WindowInfo] {
        let cgIndex = buildCGIndex()
        let cgByID = Dictionary(cgIndex.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        let pidsWithCGWindows = Set(cgIndex.map { $0.pid })
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var usedIDs = Set<String>()
        var usedCGIDs = Set<CGWindowID>()
        var drops: [WindowDrop] = []
        // Defer isActive until we know each PID's live front window.
        var pending: [(info: WindowInfo, ax: AXUIElement, frame: CGRect?, axIndex: Int)] = []
        // Last-known windows of apps not answering AX this pass. A hung app's windows
        // still exist; dropping their buttons until it recovers would be wrong.
        var retained: [WindowInfo] = []
        var retainedPIDs = Set<pid_t>()

        for app in apps {
            let pid = app.processIdentifier
            let appName = app.localizedName ?? app.bundleIdentifier ?? "App"
            let lastKnown = windows.filter { $0.pid == pid }

            if isBackingOff(pid) {
                retained += lastKnown
                retainedPIDs.insert(pid)
                continue
            }
            let started = CFAbsoluteTimeGetCurrent()
            guard let axWindows = AccessibilityService.windowsIfResponsive(for: pid) else {
                noteUnresponsive(pid, appName: appName)
                retained += lastKnown
                retainedPIDs.insert(pid)
                continue
            }
            observeDestruction(of: axWindows, pid: pid)

            // Windows the window server identifies directly. Their CG entries are off
            // limits to the title/frame heuristic for siblings without one.
            let directIDs = axWindows.map(AccessibilityService.windowID(of:))
            let directIDSet = Set(directIDs.compactMap { $0 })
            var appPending: [(info: WindowInfo, ax: AXUIElement, frame: CGRect?, axIndex: Int)] = []
            var appDrops: [WindowDrop] = []

            for (index, ax) in axWindows.enumerated() {
                let title = AccessibilityService.title(of: ax)
                let minimized = AccessibilityService.isMinimized(ax)
                let frame = AccessibilityService.frame(of: ax)
                let matchedCG: CGEntry?
                if let directID = directIDs[index] {
                    // Exact. No entry means buildCGIndex filtered the window out, and
                    // a heuristic guess could only hand it a sibling's entry.
                    matchedCG = cgByID[directID].flatMap { $0.pid == pid ? $0 : nil }
                } else {
                    matchedCG = matchCGWindow(
                        pid: pid,
                        title: title,
                        frame: frame,
                        index: cgIndex,
                        claimedIDs: usedCGIDs.union(directIDSet)
                    )
                }
                let cgID = directIDs[index] ?? matchedCG?.windowID
                let onScreen = matchedCG?.isOnScreen ?? !minimized

                // Skip tiny / offscreen utility that slipped through.
                // Minimized windows can report tiny Dock frames — keep them.
                if let frame, frame.width < 80 || frame.height < 80, !minimized {
                    appDrops.append(WindowDrop(
                        pid: pid,
                        appName: appName,
                        axIndex: index,
                        title: title,
                        frame: frame,
                        reason: "tinyFrame"
                    ))
                    continue
                }

                // Ghost-window guard. A real window that is not minimized always has a
                // layer-0 CG counterpart — buildCGIndex uses `.optionAll`, so windows on
                // other Spaces are included too. An AX window with no CG entry anywhere
                // for its whole PID therefore does not exist on screen, and the task
                // button built from it can never be raised (Finder keeps exactly such a
                // phantom entry when it has no open windows).
                //
                // The check is deliberately scoped to PIDs with *no* CG windows at all
                // rather than to a per-window match failure: matchCGWindow can legitimately
                // fail to pair a real window (blank CG titles without Screen Recording,
                // frames drifting mid-animation), and dropping a real sibling window would
                // be a far worse regression than tolerating a ghost next to a real one.
                if matchedCG == nil, !minimized, !pidsWithCGWindows.contains(pid) {
                    appDrops.append(WindowDrop(
                        pid: pid,
                        appName: appName,
                        axIndex: index,
                        title: title,
                        frame: frame,
                        reason: "ghostNoCGWindowForPID"
                    ))
                    continue
                }

                let id: String
                if let cgID {
                    id = "\(pid)-\(cgID)"
                    usedCGIDs.insert(cgID)
                } else {
                    // No window-server identity at all. CFHash follows the AX element
                    // rather than its z-ordered index in the AX list, so the id — and
                    // the button's slot — survives focus changes.
                    id = "\(pid)-ax-\(CFHash(ax))"
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
                    appName: appName,
                    isMinimized: minimized,
                    isOnScreen: onScreen,
                    isActive: false,
                    axElement: ax
                )
                appPending.append((info, ax, frame, index))
            }

            if CFAbsoluteTimeGetCurrent() - started > enumerationBudgetPerApp {
                noteUnresponsive(pid, appName: appName)
                if !lastKnown.isEmpty {
                    retained += lastKnown
                    retainedPIDs.insert(pid)
                    continue
                }
            } else {
                noteResponsive(pid, appName: appName)
            }
            pending += appPending
            drops += appDrops
        }

        collapseTabGroupSiblings(&pending, drops: &drops)

        WindowDiagnostics.noteDrops(drops)

        // Resolve which window is active using live AX focused/main window.
        var activeID: String?
        if let frontmostPID, retainedPIDs.contains(frontmostPID) {
            // No live AX answer to ask; keep whichever of its windows was active.
            let group = retained.filter { $0.pid == frontmostPID && !$0.isMinimized }
            activeID = resolveActiveID(
                detectedFrontID: group.first(where: \.isActive)?.id,
                candidates: group.map(\.id)
            )
        } else if let frontmostPID {
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

        return (pending.map(\.info) + retained).map { $0.with(isActive: $0.id == activeID) }
    }

    /// Collapse the extra task buttons a minimized macOS native tab group produces.
    ///
    /// Apps that use NSWindow tabbing (Ghostty, Terminal, Finder…) back every tab with a
    /// real NSWindow. While the group is on screen `kAXWindowsAttribute` publishes only
    /// the selected tab, so a one-window / three-tab terminal correctly yields one
    /// button. Minimizing the group miniaturizes each member individually and *all* of
    /// them then appear in the AX list — full-size frames, role AXWindow, subrole
    /// AXStandardWindow, minimized — so the taskbar grew three buttons for one window
    /// and collapsed back to one the instant it was restored.
    ///
    /// Tab-group members are co-located by definition, so identical pid + frame marks
    /// the group. Frame alone is *not* enough to act on: two independently minimized
    /// maximized windows legitimately share a frame, and hiding a real window is a far
    /// worse bug than tolerating an extra button (same doctrine as the ghost-window
    /// guard above). So a sibling is only dropped when it just appeared *and* an entry
    /// already on the taskbar holds its frame — exactly the minimize-time unmasking.
    /// Two separately minimized windows were both in the AX list beforehand, so both
    /// are known and neither is dropped.
    ///
    /// Consequence worth knowing: if the app starts with a tab group already minimized
    /// nothing is known yet, so the extra buttons show until the group is restored once.
    /// That is the deliberate direction to err in.
    private func collapseTabGroupSiblings(
        _ pending: inout [(info: WindowInfo, ax: AXUIElement, frame: CGRect?, axIndex: Int)],
        drops: inout [WindowDrop]
    ) {
        guard !pending.isEmpty else { return }

        let knownIDs = Set(windows.map(\.id))
        guard !knownIDs.isEmpty else { return }

        func frameKey(_ pid: pid_t, _ frame: CGRect) -> String {
            "\(pid)/\(Int(frame.origin.x))/\(Int(frame.origin.y))/\(Int(frame.width))/\(Int(frame.height))"
        }

        // Frames held by an entry the taskbar already shows. Only those can absorb a
        // newly appeared sibling.
        var claimedFrames = Set<String>()
        for entry in pending where entry.info.isMinimized && knownIDs.contains(entry.info.id) {
            if let frame = entry.frame {
                claimedFrames.insert(frameKey(entry.info.pid, frame))
            }
        }
        guard !claimedFrames.isEmpty else { return }

        var droppedIDs = Set<String>()
        for entry in pending {
            guard entry.info.isMinimized,
                  !knownIDs.contains(entry.info.id),
                  let frame = entry.frame,
                  claimedFrames.contains(frameKey(entry.info.pid, frame)) else { continue }
            droppedIDs.insert(entry.info.id)
            drops.append(WindowDrop(
                pid: entry.info.pid,
                appName: entry.info.appName,
                axIndex: entry.axIndex,
                title: entry.info.title,
                frame: frame,
                reason: "tabGroupSibling"
            ))
        }

        guard !droppedIDs.isEmpty else { return }
        pending.removeAll { droppedIDs.contains($0.info.id) }
    }

    private func enumerateViaCGFallback(apps: [NSRunningApplication]) -> [WindowInfo] {
        // Without Accessibility: prefer AppleScript window lists for scriptable apps
        // (Chrome). CG z-order does not track which Chrome window is front, so
        // index-based raise was cycling one icon and no-oping the other.
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Cached titles outlive a stale TTL, so a quit browser's entry would resurface
        // as ghost buttons on relaunch until the first fetch lands.
        let runningBundleIDs = Set(apps.compactMap(\.bundleIdentifier))
        scriptedTitleCache = scriptedTitleCache.filter { runningBundleIDs.contains($0.key) }

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

            // Include index so two windows with the same title get distinct ids.
            // (Title-only ids crashed stabilizeOrder via Dictionary(uniqueKeysWithValues:).)
            let ids = titles.enumerated().map { "script-\(bundleID)-\($0.offset)-\($0.element)" }
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
        // When *all* windows omit the onscreen flag (Claude, Slack, Calendar), the
        // filter above keeps every large surface — including classic Electron GPU
        // buffers (500×500, 800×600). Drop those only when a larger real sibling exists.
        let pidsWithNonBufferCandidate = Set(
            cgIndex
                .filter {
                    $0.bounds.width >= 200
                        && $0.bounds.height >= 200
                        && !Self.isLikelyElectronBuffer($0)
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
            } else if Self.isLikelyElectronBuffer(entry),
                      pidsWithNonBufferCandidate.contains(entry.pid) {
                continue
            } else {
                guard entry.bounds.width >= 200, entry.bounds.height >= 200 else { continue }
            }
            guard entry.bounds.width >= 200, entry.bounds.height >= 200 else { continue }
            // Calendar (and similar) exposes a narrow untitled inspector as its own CG
            // window — drop it when a larger sibling exists for the same PID.
            if Self.isLikelyAuxiliaryPanel(entry, all: cgIndex) { continue }
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
        for entry in cgIndex {
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

    nonisolated private struct CGEntry {
        let windowID: CGWindowID
        let pid: pid_t
        let title: String
        let bounds: CGRect
        let isOnScreen: Bool
        /// False when CG omits kCGWindowIsOnscreen (common for offscreen buffers).
        let onScreenKnown: Bool
    }

    /// Untitled surfaces with classic Electron offscreen/GPU buffer sizes.
    /// Only safe to drop when the same PID also has a non-buffer candidate.
    nonisolated private static func isLikelyElectronBuffer(_ entry: CGEntry) -> Bool {
        guard !entry.onScreenKnown, entry.title.isEmpty else { return false }
        let w = entry.bounds.width.rounded()
        let h = entry.bounds.height.rounded()
        // Store as (min, max) so orientation doesn't matter.
        let pair: [CGFloat] = [min(w, h), max(w, h)]
        let buffers: Set<[CGFloat]> = [
            [500, 500],
            [600, 800], // 800×600
            [600, 600],
            [300, 300],
            [400, 400]
        ]
        return buffers.contains(pair)
    }

    /// Narrow untitled side panels (Calendar inspector ~300×1000) next to a real window.
    nonisolated private static func isLikelyAuxiliaryPanel(_ entry: CGEntry, all: [CGEntry]) -> Bool {
        guard entry.title.isEmpty else { return false }
        let w = entry.bounds.width
        let h = entry.bounds.height
        guard w >= 200, h >= 200, w <= 420 else { return false }
        return all.contains { sib in
            sib.pid == entry.pid
                && sib.windowID != entry.windowID
                && sib.bounds.width >= max(500, w * 2)
                && sib.bounds.height >= 400
        }
    }

    nonisolated private func buildCGIndex() -> [CGEntry] {
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
            let bounds = Self.bounds(of: dict)
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

    nonisolated private static func bounds(of window: [String: Any]) -> CGRect {
        let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        return CGRect(
            x: bounds["X"] ?? 0,
            y: bounds["Y"] ?? 0,
            width: bounds["Width"] ?? 0,
            height: bounds["Height"] ?? 0
        )
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
            let exact = candidates.filter { $0.title == title }
            // Duplicate titles ("New Tab"): first-come handed each window its sibling's
            // id whenever AX order changed. The frame tells them apart.
            if exact.count > 1, let frame {
                return exact.min(by: { distance($0.bounds, frame) < distance($1.bounds, frame) })
            }
            if let first = exact.first {
                return first
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

    nonisolated private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = a.origin.x - b.origin.x
        let dy = a.origin.y - b.origin.y
        let dw = a.width - b.width
        let dh = a.height - b.height
        return abs(dx) + abs(dy) + abs(dw) + abs(dh)
    }
}
