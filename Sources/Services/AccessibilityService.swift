import Foundation
import AppKit
import ApplicationServices
import Darwin

enum AccessibilityService {
    static func isTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func windows(for pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let array = value as? [AXUIElement] else {
            // .cannotComplete (-25204) usually means the app is busy/unresponsive;
            // .apiDisabled (-25211) means the Accessibility grant is gone.
            if result != .success, result != .noValue, result != .attributeUnsupported {
                AppLog.throttled("axWindows-\(pid)-\(result.rawValue)", seconds: 20, level: .warn,
                                 "AXWindows failed", [
                    "pid": pid,
                    "app": NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?",
                    "status": result.rawValue
                ])
            }
            return []
        }
        let standard = array.filter { isStandardWindow($0) }
        if standard.count != array.count {
            AppLog.throttled("axNonStandard-\(pid)", seconds: 30, "AX windows filtered", [
                "pid": pid,
                "app": NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?",
                "total": array.count,
                "standard": standard.count
            ])
        }
        return standard
    }

    static func isStandardWindow(_ element: AXUIElement) -> Bool {
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
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
           let focused = value {
            return (focused as! AXUIElement)
        }
        if AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &value) == .success,
           let main = value {
            return (main as! AXUIElement)
        }
        return nil
    }

    static func deminimize(_ element: AXUIElement) {
        // Always clear minimized — isMinimized() can lie on stale AX refs (Chrome).
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }

    static func raise(_ element: AXUIElement, pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            AppLog.warn("ax raise without running app", ["pid": pid])
            deminimize(element)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            return
        }

        app.unhide()
        deminimize(element)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        // Single raise — retrying AXRaise animates the window up the z-order one step at a time.
        let raiseStatus = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        let activated = app.activate(options: [.activateIgnoringOtherApps])
        AppLog.debug("ax raise", [
            "pid": pid,
            "app": app.localizedName ?? "?",
            "raiseStatus": raiseStatus.rawValue,
            "activated": activated
        ])

        // If still miniaturized, only retry deminimize (no extra AXRaise).
        if isMinimized(element) {
            var attempts = 0
            for _ in 0..<8 {
                attempts += 1
                deminimize(element)
                if !isMinimized(element) { break }
                Thread.sleep(forTimeInterval: 0.03)
            }
            let stuck = isMinimized(element)
            if stuck {
                // Window refuses to deminimize via AX — caller's script fallback matters here.
                AppLog.warn("ax deminimize stuck", [
                    "pid": pid,
                    "app": app.localizedName ?? "?",
                    "attempts": attempts
                ])
            } else {
                AppLog.debug("ax deminimize retried", ["app": app.localizedName ?? "?", "attempts": attempts])
                AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            }
        }
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
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            AppLog.error("raiseScriptedWindow compile failed", ["app": appName])
            return false
        }
        let result = AppLog.measure("raiseScript", warnAfter: 0.5, ["app": appName]) {
            script.executeAndReturnError(&error)
        }
        let value = result.stringValue ?? ""
        if let error {
            AppLog.warn("raiseScriptedWindow error", [
                "app": appName,
                "title": title,
                "errNum": error[NSAppleScript.errorNumber] as? Int ?? 0,
                "errMsg": error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            ])
            return false
        }
        if value != "ok" {
            AppLog.warn("raiseScriptedWindow no window restored", [
                "app": appName,
                "title": title,
                "value": value
            ])
        }
        return value == "ok"
    }

    /// Activate / unhide an app when AX and AppleScript deminimize are unavailable.
    /// Does not reopen an already-running app — that can spawn a second Electron window.
    static func forceShowApp(pid: pid_t, bundleID: String?) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.unhide()
            let activated = app.activate(options: [.activateIgnoringOtherApps])
            AppLog.debug("forceShowApp activate", [
                "pid": pid,
                "app": app.localizedName ?? "?",
                "activated": activated
            ])
            return
        }
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            AppLog.warn("forceShowApp gave up", [
                "pid": pid,
                "bundleID": bundleID ?? "-",
                "reason": bundleID == nil ? "noBundleID" : "noAppURL"
            ])
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        AppLog.info("forceShowApp launching", ["bundleID": bundleID])
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error {
                AppLog.warn("forceShowApp launch failed", [
                    "bundleID": bundleID,
                    "error": error.localizedDescription
                ])
            }
        }
    }

    /// Front-to-back window titles from the app's scripting interface.
    static func scriptedWindowTitles(bundleID: String) -> [String] {
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
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return [] }
        let result = AppLog.measure("scriptedWindowTitles", warnAfter: 0.4, ["bundleID": bundleID]) {
            script.executeAndReturnError(&error)
        }
        if let error {
            // errNum -1743 = Automation permission not granted for this target.
            AppLog.throttled("titlesErr-\(bundleID)", seconds: 30, level: .warn,
                             "scriptedWindowTitles error", [
                "bundleID": bundleID,
                "errNum": error[NSAppleScript.errorNumber] as? Int ?? 0,
                "errMsg": error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            ])
            return []
        }

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
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return "err:no-script" }
        let result = AppLog.measure("minimizeScript", warnAfter: 0.5, ["app": appName]) {
            script.executeAndReturnError(&error)
        }
        if let error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            let num = error[NSAppleScript.errorNumber] as? Int ?? 0
            return "err:ns:\(num):\(msg)"
        }
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
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        let result = AppLog.measure("minimizeViaMenu", warnAfter: 0.5, ["app": appName]) {
            script.executeAndReturnError(&error)
        }
        let value = result.stringValue ?? ""
        let ok = error == nil && value.hasPrefix("ok")
        if !ok {
            AppLog.warn("minimizeViaMenu failed", [
                "app": appName,
                "value": value,
                "errNum": error?[NSAppleScript.errorNumber] as? Int ?? 0
            ])
        }
        return ok
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

    /// Live AX window for a taskbar entry — cached ref, then title match, then first window.
    static func resolveWindow(pid: pid_t, title: String, cached: AXUIElement?) -> AXUIElement? {
        let axWindows = windows(for: pid)
        if let cached, axWindows.contains(where: { CFEqual($0, cached) }) {
            return cached
        }
        if !title.isEmpty {
            if let match = axWindows.first(where: { self.title(of: $0) == title }) {
                AppLog.debug("resolveWindow via title", ["pid": pid, "title": title])
                return match
            }
        }
        // Falling back to the first window is how the *wrong* window gets raised
        // when an app has several — worth seeing in the log.
        AppLog.debug("resolveWindow fallback", [
            "pid": pid,
            "title": title,
            "axWindows": axWindows.count,
            "strategy": axWindows.isEmpty ? "none" : "firstWindow"
        ])
        return axWindows.first
    }

    /// Close one window (not quit). Presses the AX close button; falls back to Cmd+W.
    static func close(_ element: AXUIElement, pid: pid_t? = nil) {
        var closeButton: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeButton)
        if result == .success, let button = closeButton {
            let press = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            AppLog.debug("ax close button pressed", ["pid": pid ?? -1, "status": press.rawValue])
            return
        }
        AppLog.debug("ax close falling back to cmdW", ["pid": pid ?? -1, "status": result.rawValue])
        // Fallback: focus the window then send Cmd+W (closes window, does not quit).
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        if let pid, let app = NSRunningApplication(processIdentifier: pid) {
            _ = app.activate(options: [.activateIgnoringOtherApps])
        }
        postCommandW()
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
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        let result = AppLog.measure("closeScript", warnAfter: 0.5, ["app": appName]) {
            script.executeAndReturnError(&error)
        }
        let value = result.stringValue ?? ""
        if let error {
            AppLog.warn("closeScriptedWindow error", [
                "app": appName,
                "title": title,
                "errNum": error[NSAppleScript.errorNumber] as? Int ?? 0,
                "errMsg": error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            ])
            return false
        }
        if value != "ok" {
            AppLog.warn("closeScriptedWindow no window closed", ["app": appName, "title": title, "value": value])
        }
        return value == "ok"
    }

    /// Synthetic ⌘W — closes the front window of the active app without quitting.
    static func postCommandW() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x0D, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x0D, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Windows-style Show Desktop via Dock's Mission Control notification.
    /// AppKit hide() / hideOtherApplications fail from an accessory (LSUIElement) app.
    static func toggleShowDesktop() {
        let ok = postShowDesktopNotification()
        AppLog.info("showDesktop", ["ok": ok])
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
            guard let handle = dlopen(path, RTLD_LAZY) else {
                let reason = dlerror().map { String(cString: $0) } ?? "unknown"
                AppLog.debug("dlopen failed", ["path": path, "error": reason])
                continue
            }
            defer { dlclose(handle) }
            guard let sym = dlsym(handle, "CoreDockSendNotification") else {
                AppLog.debug("dlsym CoreDockSendNotification missing", ["path": path])
                continue
            }
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

    // MARK: - Helpers

    private static func stringValue(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private static func boolValue(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return (value as? Bool) ?? ((value as! CFBoolean) == kCFBooleanTrue)
    }

    private static func positionValue(_ element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let axValue = value else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeValue(_ element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let axValue = value else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue as! AXValue, .cgSize, &size) else { return nil }
        return size
    }
}
