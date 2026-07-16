import AppKit

/// Opens the Start menu for the configured hotkey (default: Windows / ⌘ alone).
final class StartHotkeyMonitor {
    static let shared = StartHotkeyMonitor()

    /// When true, the monitor ignores input (e.g. while Settings is recording a new shortcut).
    var isSuspended = false

    private var localFlagsMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?

    private var modifierHeld = false
    private var chordUsed = false

    private init() {}

    func start() {
        stop()

        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
        }

        AppLog.info("StartHotkeyMonitor.start", [
            "hotkey": TaskbarSettings.shared.startMenuHotkey.displayString,
            "localFlags": localFlagsMonitor != nil,
            "globalFlags": globalFlagsMonitor != nil
        ])
    }

    func stop() {
        if let localFlagsMonitor {
            NSEvent.removeMonitor(localFlagsMonitor)
            self.localFlagsMonitor = nil
        }
        if let globalFlagsMonitor {
            NSEvent.removeMonitor(globalFlagsMonitor)
            self.globalFlagsMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        modifierHeld = false
        chordUsed = false
    }

    private var configuredHotkey: StartMenuHotkey { TaskbarSettings.shared.startMenuHotkey }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard !isSuspended else { return }
        let hotkey = configuredHotkey
        guard hotkey.modifierOnly else { return }
        guard let targetFlag = StartMenuHotkey.modifierFlag(forKeyCode: hotkey.keyCode) else { return }

        let isTargetKey = StartMenuHotkey.isSameModifierKey(event.keyCode, hotkey.keyCode)
        let flagDown = event.modifierFlags.contains(targetFlag)

        if isTargetKey {
            if flagDown, !modifierHeld {
                modifierHeld = true
                chordUsed = hasExtraModifiers(event.modifierFlags, besides: targetFlag)
            } else if !flagDown, modifierHeld {
                let shouldToggle = !chordUsed
                modifierHeld = false
                chordUsed = false
                if shouldToggle {
                    fireToggle()
                }
            }
        } else if modifierHeld, hasExtraModifiers(event.modifierFlags, besides: targetFlag) {
            chordUsed = true
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard !isSuspended else { return }
        let hotkey = configuredHotkey

        if hotkey.modifierOnly {
            guard modifierHeld else { return }
            if StartMenuHotkey.isSameModifierKey(event.keyCode, hotkey.keyCode) { return }
            chordUsed = true
            return
        }

        guard !event.isARepeat else { return }
        guard event.keyCode == hotkey.keyCode else { return }

        let eventMods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard eventMods == hotkey.nsModifierFlags else { return }
        fireToggle()
    }

    private func hasExtraModifiers(_ flags: NSEvent.ModifierFlags, besides target: NSEvent.ModifierFlags) -> Bool {
        let others: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
        return !flags.intersection(others.subtracting(target)).isEmpty
    }

    private func fireToggle() {
        DispatchQueue.main.async {
            TaskbarPanelController.shared.toggleStartMenu()
        }
    }
}
