import Foundation
import AppKit
import ApplicationServices
import Darwin

// Deprecated Process Manager symbols are unavailable to Swift (macOS 10.9+), but still
// export from ApplicationServices. Front-window-only activation needs them — same
// approach as AltTab / WindowFairy after Big Sur broke NSRunningApplication.activate.
@_silgen_name("GetProcessForPID")
private func BMTGetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
@_silgen_name("SetFrontProcessWithOptions")
private func BMTSetFrontProcessWithOptions(
    _ psn: UnsafePointer<ProcessSerialNumber>,
    _ options: OptionBits
) -> OSStatus
private let kBMTFrontWindowOnly: OptionBits = 1

// Private but stable since 10.x: the CGWindowID behind an AX window. Every macOS window
// manager (Rectangle, AltTab, yabai) relies on it — there is no public AX→CG mapping.
@_silgen_name("_AXUIElementGetWindow")
private func BMTAXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AccessibilityService {
    /// AX calls block until the target app answers, and the default is ~6s. Enumeration
    /// runs on the main thread, so one beachballing app would freeze the taskbar that
    /// long per call. A responsive app answers in well under a millisecond.
    static let messagingTimeout: Float = 0.25

    static func isTrusted(prompt: Bool) -> Bool {
        // The value of kAXTrustedCheckOptionPrompt. The SDK imports that constant as a
        // mutable global, which strict concurrency rejects as shared state.
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// The only way this app should create an application element. The timeout is
    /// per element, so it is also applied to every window element handed out below.
    static func applicationElement(for pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        return app
    }

    static func windows(for pid: pid_t) -> [AXUIElement] {
        windowsIfResponsive(for: pid) ?? []
    }

    /// Standard windows for `pid`, or nil when the app did not answer within the
    /// messaging timeout. Distinct from an empty list: a hung app still has windows,
    /// and callers keep showing them rather than dropping them.
    static func windowsIfResponsive(for pid: pid_t) -> [AXUIElement]? {
        let app = applicationElement(for: pid)
        var value: CFTypeRef?
        let started = CFAbsoluteTimeGetCurrent()
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard result == .success else {
            // cannotComplete is also returned instantly by apps that are still launching
            // or have no AX support; only a call that burned the timeout means "hung".
            let timedOut = result == .cannotComplete
                && CFAbsoluteTimeGetCurrent() - started >= Double(messagingTimeout) * 0.8
            return timedOut ? nil : []
        }
        return axElements(value).filter { isStandardWindow($0) }
    }

    /// The window's CGWindowID, straight from the window server — exact even when
    /// titles are blank or two windows share a frame.
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var windowID: CGWindowID = 0
        guard BMTAXUIElementGetWindow(element, &windowID) == .success, windowID != 0 else { return nil }
        return windowID
    }

    /// Type-checked AX element array from a raw attribute value, with the messaging
    /// timeout applied (elements do not inherit it from the app element).
    static func axElements(_ value: CFTypeRef?) -> [AXUIElement] {
        guard let array = value as? [CFTypeRef] else { return [] }
        return array.compactMap { axElement($0) }
    }

    private static func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    static func isStandardWindow(_ element: AXUIElement) -> Bool {
        // Role first. kAXWindowsAttribute is not guaranteed to contain only windows:
        // Finder publishes its desktop there as a full-screen AXScrollArea with an
        // empty subrole, which slipped past the subrole check below and produced a
        // permanent Finder task button that no click could ever raise.
        if let role = stringValue(element, kAXRoleAttribute as CFString),
           role != kAXWindowRole as String {
            return false
        }

        if let subrole = stringValue(element, kAXSubroleAttribute as CFString),
           !subrole.isEmpty {
            let allowed: Set<String> = [
                kAXStandardWindowSubrole as String,
                kAXDialogSubrole as String
            ]
            // Reject AXUnknown / floating / system panels. Calendar’s side inspector is
            // AXUnknown (~300pt) and used to appear as a second identical taskbar icon.
            if !allowed.contains(subrole) {
                return false
            }
        }
        // Minimized windows sometimes report Dock-sized frames — never drop them.
        if isMinimized(element) {
            return true
        }
        let size = sizeValue(element)
        if let size, size.width < 80 || size.height < 80 {
            return false
        }
        return true
    }

    static func title(of element: AXUIElement) -> String {
        stringValue(element, kAXTitleAttribute as CFString) ?? ""
    }

    static func isMinimized(_ element: AXUIElement) -> Bool {
        boolValue(element, kAXMinimizedAttribute as CFString) ?? false
    }

    /// True when the window is in macOS fullscreen (green button). Fullscreen windows
    /// live on their own Space and refuse AXMinimized, so a taskbar click must raise
    /// them rather than try — and fail — to minimize.
    static func isFullScreen(_ element: AXUIElement) -> Bool {
        boolValue(element, "AXFullScreen" as CFString) ?? false
    }

    static func isMain(_ element: AXUIElement) -> Bool {
        boolValue(element, kAXMainAttribute as CFString) ?? false
    }

    static func isFocused(_ element: AXUIElement) -> Bool {
        boolValue(element, kAXFocusedAttribute as CFString) ?? false
    }

    /// Front window for an app. Prefer focused (updates on click); main is a fallback.
    static func frontWindow(for pid: pid_t) -> AXUIElement? {
        let app = applicationElement(for: pid)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
           let focused = axElement(value) {
            return focused
        }
        if AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &value) == .success,
           let main = axElement(value) {
            return main
        }
        return nil
    }

    static func deminimize(_ element: AXUIElement) {
        // Always clear minimized — isMinimized() can lie on stale AX refs (Chrome).
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }

    static func raise(_ element: AXUIElement, pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            deminimize(element)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            return
        }

        app.unhide()
        deminimize(element)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        // Single raise — retrying AXRaise animates the window up the z-order one step at a time.
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        // Front-window-only: plain activate() stacks every sibling above other apps.
        _ = activateFrontWindowOnly(pid: pid)

        // If still miniaturized, only retry deminimize (no extra AXRaise).
        if isMinimized(element) {
            for _ in 0..<8 {
                deminimize(element)
                if !isMinimized(element) { break }
                Thread.sleep(forTimeInterval: 0.03)
            }
            if !isMinimized(element) {
                AXUIElementPerformAction(element, kAXRaiseAction as CFString)
                _ = activateFrontWindowOnly(pid: pid)
            }
        }
    }

    /// Activate an app without dragging every sibling window above other apps.
    ///
    /// Since Big Sur, `NSRunningApplication.activate` often brings *all* windows
    /// forward even without `.activateAllWindows`. After AXRaise / AXMain, the
    /// deprecated Process Manager "front window only" option still raises just
    /// the key/main window (WindowFairy / AltTab pattern).
    @discardableResult
    static func activateFrontWindowOnly(pid: pid_t) -> Bool {
        var psn = ProcessSerialNumber()
        guard BMTGetProcessForPID(pid, &psn) == noErr else {
            return NSRunningApplication(processIdentifier: pid)?
                .activate(options: [.activateIgnoringOtherApps]) ?? false
        }
        if BMTSetFrontProcessWithOptions(&psn, kBMTFrontWindowOnly) == noErr {
            return true
        }
        return NSRunningApplication(processIdentifier: pid)?
            .activate(options: [.activateIgnoringOtherApps]) ?? false
    }

    /// Raise a specific window by title (stable). Index-based raise is wrong because
    /// CG z-order does not track Chrome's front window.
    ///
    /// System Events (by pid) runs first — Chrome's `miniaturized` property often
    /// errors, and app-script titles can be truncated with "…" while AX titles are full.
    @discardableResult
    static func raiseScriptedWindow(bundleID: String?, appName: String, title: String, pid: pid_t? = nil) -> Bool {
        if let bundleID, !bundleID.isEmpty {
            // prompt=false: never re-ask on every Chrome click. Grant once via
            // System Settings → Privacy → Automation (or the status-menu link).
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            _ = AEDeterminePermissionToAutomateTarget(
                target.aeDesc,
                typeWildCard,
                typeWildCard,
                false
            )
        }
        let seTarget = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
        _ = AEDeterminePermissionToAutomateTarget(
            seTarget.aeDesc,
            typeWildCard,
            typeWildCard,
            false
        )

        let tellTarget: String
        if let bundleID, !bundleID.isEmpty {
            tellTarget = "id \"\(bundleID)\""
        } else {
            let escapedName = appName
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            tellTarget = "\"\(escapedName)\""
        }
        let escapedName = appName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedTitle = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // Prefix helps when Chrome's scripting dictionary truncates titles.
        let titlePrefix = String(title.prefix(40))
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let processTell: String
        if let pid {
            processTell = "process id \(pid)"
        } else {
            processTell = "process \"\(escapedName)\""
        }

        let source = """
        set restored to false
        try
          tell application "System Events"
            tell \(processTell)
              if "\(escapedTitle)" is not "" then
                set wins to windows whose title is "\(escapedTitle)"
                if (count of wins) > 0 then
                  set value of attribute "AXMinimized" of item 1 of wins to false
                  perform action "AXRaise" of item 1 of wins
                  set restored to true
                end if
                if restored is false and "\(titlePrefix)" is not "" then
                  repeat with w in windows
                    try
                      if title of w starts with "\(titlePrefix)" then
                        set value of attribute "AXMinimized" of w to false
                        perform action "AXRaise" of w
                        set restored to true
                        exit repeat
                      end if
                    end try
                  end repeat
                end if
              end if
              if restored is false then
                set miniWins to windows whose value of attribute "AXMinimized" is true
                if (count of miniWins) = 1 then
                  set value of attribute "AXMinimized" of item 1 of miniWins to false
                  perform action "AXRaise" of item 1 of miniWins
                  set restored to true
                end if
              end if
            end tell
          end tell
        end try
        if restored is false and "\(escapedTitle)" is not "" then
          try
            tell application \(tellTarget)
              try
                set targetWindow to first window whose title is "\(escapedTitle)"
                try
                  set miniaturized of targetWindow to false
                  set restored to true
                end try
                try
                  set index of targetWindow to 1
                end try
                activate
              end try
            end tell
          end try
        end if
        if restored is false then
          try
            tell application \(tellTarget)
              try
                reopen
              end try
              activate
              try
                set miniaturized of every window to false
                set restored to true
              end try
              if restored is false then
                try
                  repeat with w in windows
                    try
                      set miniaturized of w to false
                      set restored to true
                    end try
                  end repeat
                end try
              end if
            end tell
          end try
        end if
        if restored then
          return "ok"
        else
          return "err"
        end if
        """
        let (result, error) = runScript(source)
        return error == nil && result?.stringValue == "ok"
    }

    /// Activate / unhide an app when AX and AppleScript deminimize are unavailable.
    /// Does not reopen an already-running app — that can spawn a second Electron window.
    /// Uses front-window-only activation so sibling windows stay behind other apps.
    static func forceShowApp(pid: pid_t, bundleID: String?) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.unhide()
            _ = activateFrontWindowOnly(pid: pid)
            return
        }
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
    }

    /// Front-to-back window titles from the app's scripting interface, fetched on the
    /// script queue and delivered on main. Asynchronous because a busy browser can take
    /// up to the script timeout to answer, and this is polled from the refresh loop.
    static func fetchScriptedWindowTitles(bundleID: String, completion: @escaping @MainActor @Sendable ([String]) -> Void) {
        scriptQueue.async {
            let titles = scriptedWindowTitlesOnScriptQueue(bundleID: bundleID)
            DispatchQueue.main.async { completion(titles) }
        }
    }

    private static func scriptedWindowTitlesOnScriptQueue(bundleID: String) -> [String] {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        _ = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
        let source = """
        tell application id "\(bundleID)"
          try
            set out to {}
            repeat with w in windows
              set end of out to title of w
            end repeat
            return out
          on error
            return {}
          end try
        end tell
        """
        let (result, error) = runScriptOnScriptQueue(source)
        guard error == nil, let result else { return [] }

        var titles: [String] = []
        let count = result.numberOfItems
        if count > 0 {
            for i in 1...count {
                if let item = result.atIndex(i)?.stringValue {
                    titles.append(item)
                }
            }
            return titles
        }
        if let single = result.stringValue, !single.isEmpty {
            return [single]
        }
        return []
    }

    static func minimize(_ element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    /// Minimize a window by title via AppleScript / System Events.
    /// Returns a status string for debug logging: "ok-…", or "err:…".
    @discardableResult
    static func minimizeScriptedWindow(bundleID: String?, appName: String, title: String) -> Bool {
        minimizeScriptedWindowStatus(bundleID: bundleID, appName: appName, title: title).hasPrefix("ok")
    }

    static func minimizeScriptedWindowStatus(bundleID: String?, appName: String, title: String) -> String {
        if let bundleID, !bundleID.isEmpty {
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            _ = AEDeterminePermissionToAutomateTarget(
                target.aeDesc,
                typeWildCard,
                typeWildCard,
                false
            )
        }

        let tellTarget: String
        if let bundleID, !bundleID.isEmpty {
            tellTarget = "id \"\(bundleID)\""
        } else {
            let escapedName = appName
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            tellTarget = "\"\(escapedName)\""
        }
        let escapedName = appName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedTitle = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        // CRITICAL: Chrome rejects `set miniaturized of front window to true` (-1700)
        // but accepts `tell front window / set miniaturized to true`.
        // Cursor/Electron often accepts the set with NO effect — must verify by reading back.
        let source = """
        set how to "err"
        set detail to ""
        tell application \(tellTarget)
          try
            if "\(escapedTitle)" is not "" then
              tell (first window whose title is "\(escapedTitle)")
                set miniaturized to true
              end tell
              try
                if miniaturized of (first window whose title is "\(escapedTitle)") then
                  set how to "ok-app-title"
                else
                  set detail to "app-title-noop"
                end if
              on error errMsg number errNum
                set detail to "app-title-verify:" & errNum & ":" & errMsg
              end try
            end if
          on error errMsg number errNum
            set detail to "app-title:" & errNum & ":" & errMsg
          end try
          if how is "err" then
            try
              tell front window
                set miniaturized to true
              end tell
              try
                if miniaturized of front window then
                  set how to "ok-app-front"
                else
                  set detail to detail & " app-front-noop"
                end if
              on error errMsg number errNum
                set detail to detail & " app-front-verify:" & errNum & ":" & errMsg
              end try
            on error errMsg number errNum
              set detail to detail & " app-front:" & errNum & ":" & errMsg
            end try
          end if
        end tell
        if how is "err" then
          try
            tell application "System Events"
              tell process "\(escapedName)"
                if "\(escapedTitle)" is not "" then
                  try
                    set wins to windows whose title is "\(escapedTitle)"
                    if (count of wins) > 0 then
                      set value of attribute "AXMinimized" of item 1 of wins to true
                      set how to "ok-se-title"
                    end if
                  on error errMsg number errNum
                    set detail to detail & " se-title:" & errNum & ":" & errMsg
                  end try
                end if
                if how is "err" then
                  try
                    set value of attribute "AXMinimized" of front window to true
                    set how to "ok-se-front"
                  on error errMsg number errNum
                    set detail to detail & " se-front:" & errNum & ":" & errMsg
                  end try
                end if
              end tell
            end tell
          on error errMsg number errNum
            set detail to detail & " se-outer:" & errNum & ":" & errMsg
          end try
        end if
        if how is "err" then
          return "err:" & detail
        end if
        return how
        """
        let (result, error) = runScript(source)
        if let error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            let num = error[NSAppleScript.errorNumber] as? Int ?? 0
            return "err:ns:\(num):\(msg)"
        }
        guard let result else { return "err:no-script" }
        return result.stringValue ?? "err:empty"
    }

    /// Click Window → Minimize via System Events (needs Accessibility).
    @discardableResult
    static func minimizeViaMenu(appName: String) -> Bool {
        let escapedName = appName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        try
          tell application "System Events"
            tell process "\(escapedName)"
              set frontmost to true
              try
                click menu item "Minimize" of menu "Window" of menu bar 1
                return "ok"
              end try
              try
                click (first button of front window whose subrole is "AXMinimizeButton")
                return "ok-btn"
              end try
            end tell
          end tell
        on error
          return "err"
        end try
        return "err"
        """
        let (result, error) = runScript(source)
        return error == nil && (result?.stringValue ?? "").hasPrefix("ok")
    }

    /// Synthetic ⌘M — only delivered when this process has Accessibility (or equivalent Input Monitoring).
    static func postCommandM() {
        let cgSource = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: cgSource, virtualKey: 0x2E, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: cgSource, virtualKey: 0x2E, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Minimize a window that is in full screen. Full-screen windows ignore AXMinimized,
    /// so leave full screen first; minimize requests sent during the Space transition
    /// are dropped as well, so keep retrying until one sticks. Blocks for up to ~2s.
    static func minimizeLeavingFullScreen(_ element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, kCFBooleanFalse)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.15)
            guard !isFullScreen(element) else { continue }
            minimize(element)
            if isMinimized(element) { return true }
        }
        return false
    }

    /// Close one window (not quit). Presses the AX close button; falls back to Cmd+W.
    static func close(_ element: AXUIElement, pid: pid_t) {
        var closeButton: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeButton)
        if result == .success, let button = axElement(closeButton) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
            return
        }
        // Raise first so Cmd+W lands on this window rather than a sibling.
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        closeFrontWindowViaCommandW(pid: pid)
    }

    /// Cmd+W to `pid`'s front window (closes the window, does not quit). Activation is
    /// asynchronous, so a keystroke sent straight after it lands in whatever app was
    /// still frontmost — closing, say, a Safari tab. Wait for `pid` to really be in
    /// front and give up rather than guess. Blocks for up to ~300ms.
    @discardableResult
    static func closeFrontWindowViaCommandW(pid: pid_t) -> Bool {
        func isFrontmost() -> Bool {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        }
        if !isFrontmost() {
            activateFrontWindowOnly(pid: pid)
        }
        let deadline = Date().addingTimeInterval(0.3)
        while !isFrontmost() {
            guard Date() < deadline else {
                AppLog.warn("cmd-W close skipped: app never became frontmost", ["pid": Int(pid)])
                return false
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        postCommandW(to: pid)
        return true
    }

    /// Close a window by title via AppleScript / System Events (no cached AX required).
    @discardableResult
    static func closeScriptedWindow(bundleID: String?, appName: String, title: String) -> Bool {
        guard !title.isEmpty else { return false }

        if let bundleID, !bundleID.isEmpty {
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            _ = AEDeterminePermissionToAutomateTarget(
                target.aeDesc,
                typeWildCard,
                typeWildCard,
                false
            )
        }

        let tellTarget: String
        if let bundleID, !bundleID.isEmpty {
            tellTarget = "id \"\(bundleID)\""
        } else {
            let escapedName = appName
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            tellTarget = "\"\(escapedName)\""
        }
        let escapedName = appName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedTitle = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        set closedWin to false
        tell application \(tellTarget)
          try
            close (first window whose title is "\(escapedTitle)")
            set closedWin to true
          end try
        end tell
        if closedWin is false then
          try
            tell application "System Events"
              tell process "\(escapedName)"
                set wins to windows whose title is "\(escapedTitle)"
                if (count of wins) > 0 then
                  try
                    perform action "AXPress" of (value of attribute "AXCloseButton" of item 1 of wins)
                    set closedWin to true
                  end try
                  if closedWin is false then
                    try
                      click (first button of item 1 of wins whose subrole is "AXCloseButton")
                      set closedWin to true
                    end try
                  end if
                end if
              end tell
            end tell
          end try
        end if
        if closedWin then
          return "ok"
        else
          return "err"
        end if
        """
        let (result, error) = runScript(source)
        return error == nil && result?.stringValue == "ok"
    }

    /// Synthetic ⌘W addressed to `pid`, so it cannot reach another app even if focus
    /// moves between the frontmost check and delivery.
    private static func postCommandW(to pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x0D, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x0D, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.postToPid(pid)
        keyUp?.postToPid(pid)
    }

    /// Windows-style Show Desktop via Dock's Mission Control notification.
    /// AppKit hide() / hideOtherApplications fail from an accessory (LSUIElement) app.
    static func toggleShowDesktop() {
        _ = postShowDesktopNotification()
    }

    /// Back-compat name used by older call sites.
    static func hideAllWindows() {
        toggleShowDesktop()
    }

    /// `CoreDockSendNotification("com.apple.showdesktop.awake")` — same as Mission Control → Show Desktop.
    @discardableResult
    private static func postShowDesktopNotification() -> Bool {
        let paths = [
            "/System/Library/PrivateFrameworks/Dock.framework/Dock",
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        ]
        for path in paths {
            guard let handle = dlopen(path, RTLD_LAZY) else { continue }
            defer { dlclose(handle) }
            guard let sym = dlsym(handle, "CoreDockSendNotification") else { continue }
            typealias CoreDockFn = @convention(c) (CFString, Int32) -> Void
            let fn = unsafeBitCast(sym, to: CoreDockFn.self)
            fn("com.apple.showdesktop.awake" as CFString, 0)
            return true
        }
        return false
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = positionValue(element), let size = sizeValue(element) else { return nil }
        return CGRect(origin: position, size: size)
    }

    // MARK: - AppleScript

    /// NSAppleScript is not thread-safe, and raise, minimize, close and title polling
    /// run scripts from different threads. Every script goes through this one queue.
    private static let scriptQueue = DispatchQueue(label: "BetterMacTaskbar.applescript", qos: .userInitiated)

    /// Run a script on the script queue, blocking the caller. Not for the main thread —
    /// a slow target app holds the caller for up to the script timeout per event.
    private static func runScript(_ source: String) -> (result: NSAppleEventDescriptor?, error: NSDictionary?) {
        dispatchPrecondition(condition: .notOnQueue(scriptQueue))
        return scriptQueue.sync { runScriptOnScriptQueue(source) }
    }

    private static func runScriptOnScriptQueue(_ source: String) -> (result: NSAppleEventDescriptor?, error: NSDictionary?) {
        dispatchPrecondition(condition: .onQueue(scriptQueue))
        // Apple events wait two minutes for a reply by default. A hung browser would
        // hold the queue — and every raise queued behind it — for that long.
        let bounded = "with timeout of 1 second\n\(source)\nend timeout"
        guard let script = NSAppleScript(source: bounded) else { return (nil, nil) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return (result, error)
    }

    // MARK: - Helpers

    /// Internal rather than private so WindowDiagnostics can report raw role/subrole
    /// attributes in its snapshot without duplicating the AX plumbing.
    static func stringValue(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private static func boolValue(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean))
        }
        // Some apps answer boolean attributes with a CFNumber.
        return (value as? NSNumber)?.boolValue
    }

    private static func positionValue(_ element: AXUIElement) -> CGPoint? {
        guard let axValue = axValue(element, kAXPositionAttribute as CFString) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeValue(_ element: AXUIElement) -> CGSize? {
        guard let axValue = axValue(element, kAXSizeAttribute as CFString) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func axValue(_ element: AXUIElement, _ attribute: CFString) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }
}
