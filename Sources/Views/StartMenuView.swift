import AppKit

final class StartButtonView: NSView {
    var onToggle: (() -> Void)?
    private var tracking: NSTrackingArea?
    private let logo = StartLogoView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        logo.translatesAutoresizingMaskIntoConstraints = false
        addSubview(logo)
        NSLayoutConstraint.activate([
            logo.centerXAnchor.constraint(equalTo: centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 24),
            logo.heightAnchor.constraint(equalToConstant: 24)
        ])
        toolTip = "Start"
    }

    required init?(coder: NSCoder) { fatalError() }

    func setHighlighted(_ on: Bool) {
        layer?.backgroundColor = on
            ? NSColor(calibratedRed: 0, green: 0.47, blue: 0.84, alpha: 1).cgColor
            : NSColor.clear.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) {
        if layer?.backgroundColor == NSColor.clear.cgColor || layer?.backgroundColor == nil {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        // Keep blue if open — controller manages that
        if layer?.backgroundColor != NSColor(calibratedRed: 0, green: 0.47, blue: 0.84, alpha: 1).cgColor {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }
}

final class StartLogoView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        let gap: CGFloat = 2.5
        let tile = (bounds.width - gap) / 2
        let rects = [
            NSRect(x: 0, y: 0, width: tile, height: tile),
            NSRect(x: tile + gap, y: 0, width: tile, height: tile),
            NSRect(x: 0, y: tile + gap, width: tile, height: tile),
            NSRect(x: tile + gap, y: tile + gap, width: tile, height: tile)
        ]
        for r in rects {
            NSBezierPath(roundedRect: r, xRadius: 0.5, yRadius: 0.5).fill()
        }
    }
}

/// Borderless panels refuse key status by default — start-menu search needs a key window.
private final class StartMenuKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class StartMenuController {
    private var panel: NSPanel?
    private weak var anchor: NSView?
    private var panelWasVisible = false
    private var localMonitor: Any?
    private var globalMonitor: Any?

    /// Fired whenever the menu is dismissed (outside click, launch, settings, toggle, etc.).
    var onHide: (() -> Void)?

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(relativeTo view: NSView) {
        if isVisible {
            hide()
        } else {
            show(relativeTo: view)
        }
    }

    func hide() {
        let wasVisible = panel != nil
        removeMonitors()
        panel?.orderOut(nil)
        panel = nil
        if panelWasVisible {
            TaskbarPanelController.shared.endKeepVisible()
            panelWasVisible = false
        }
        if wasVisible {
            onHide?()
        }
    }

    private func show(relativeTo view: NSView) {
        let width: CGFloat = 360
        let height: CGFloat = 420
        let content = StartMenuView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.onLaunch = { [weak self] bundleID in
            PinManager.launch(bundleID: bundleID)
            self?.hide()
        }
        content.onSettings = { [weak self] in
            self?.hide()
            SettingsWindowController.shared.show()
        }
        content.onQuit = {
            AppLog.info("quit requested", ["source": "startMenu"])
            NSApp.terminate(nil)
        }
        content.onRequestClose = { [weak self] in
            self?.hide()
        }

        let panel = StartMenuKeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = content

        guard let window = view.window else { return }
        let screenFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
        let x = screenFrame.minX
        let y = screenFrame.maxY
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        // Accessory (LSUIElement) apps must activate before a panel can take keyboard focus.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
        self.anchor = view
        installMonitors()
        if !panelWasVisible {
            panelWasVisible = true
            TaskbarPanelController.shared.beginKeepVisible()
        }
    }

    private func installMonitors() {
        removeMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                return self.handleKeyDown(event)
            }
            self.handleMouseDown(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard isVisible, let content = panel?.contentView as? StartMenuView else { return event }
        if content.handleSearchKeyDown(event) {
            return nil
        }
        if event.keyCode == 53 { // Escape
            hide()
            return nil
        }
        return content.handleTypeToSearch(event)
    }

    private func removeMonitors() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard let panel else { return }
        let location = NSEvent.mouseLocation
        if panel.frame.contains(location) { return }
        // Let the Start button handle its own toggle.
        if let anchor, let window = anchor.window {
            let anchorScreen = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            if anchorScreen.contains(location) { return }
        }
        hide()
    }
}

fileprivate struct InstalledApp {
    let bundleID: String
    let name: String
}

fileprivate enum AppCatalog {
    private static var cached: [InstalledApp]?
    private static var cacheDate: Date?
    private static let cacheTTL: TimeInterval = 60

    static func allApps() -> [InstalledApp] {
        if let cached, let cacheDate, Date().timeIntervalSince(cacheDate) < cacheTTL {
            return cached
        }
        let apps = scanInstalledApps()
        cached = apps
        cacheDate = Date()
        return apps
    }

    static func invalidateCache() {
        cached = nil
        cacheDate = nil
    }

    private static func scanInstalledApps() -> [InstalledApp] {
        let fm = FileManager.default
        var roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: "/Applications/Utilities")
        ]
        let homeApps = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications")
        roots.append(homeApps)

        var seen = Set<String>()
        var results: [InstalledApp] = []

        for root in roots {
            guard fm.fileExists(atPath: root.path) else { continue }
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension == "app" else { continue }
                guard let bundle = Bundle(url: url),
                      let bundleID = bundle.bundleIdentifier,
                      !bundleID.isEmpty,
                      !seen.contains(bundleID) else { continue }
                seen.insert(bundleID)
                let name = fm.displayName(atPath: url.path)
                results.append(InstalledApp(bundleID: bundleID, name: name))
            }
        }

        results.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return results
    }
}

final class StartMenuView: NSView, NSSearchFieldDelegate {
    var onLaunch: ((String) -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var onRequestClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "PINNED")
    private let searchField = NSSearchField()
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let document = NSView()

    private var pinnedApps: [(String, String)] = []
    private var filteredApps: [(String, String)] = []
    private var resultRows: [StartMenuRow] = []
    private var selectedIndex: Int = -1
    private var searchVisible = false
    private var searchHeightConstraint: NSLayoutConstraint?
    private var scrollTopToTitle: NSLayoutConstraint?
    private var scrollTopToSearch: NSLayoutConstraint?

    var hasSearchQuery: Bool {
        !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isSearching: Bool { searchVisible }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.94).cgColor
        layer?.cornerRadius = 0

        let effect = NSVisualEffectView(frame: bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        addSubview(effect, positioned: .below, relativeTo: nil)

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = NSColor.secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        searchField.placeholderString = "Type to search"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.isHidden = true
        searchField.alphaValue = 0
        addSubview(searchField)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        document.addSubview(stack)
        scroll.documentView = document
        addSubview(scroll)

        pinnedApps = Self.loadPinnedApps()
        rebuildRows(apps: pinnedApps, allowSelection: false)

        let settings = makeFooterButton(title: "Settings", action: #selector(settingsClicked))
        let quit = makeFooterButton(title: "Quit Taskbar", action: #selector(quitClicked))
        settings.translatesAutoresizingMaskIntoConstraints = false
        quit.translatesAutoresizingMaskIntoConstraints = false
        addSubview(settings)
        addSubview(quit)

        let searchHeight = searchField.heightAnchor.constraint(equalToConstant: 0)
        searchHeightConstraint = searchHeight
        let topToTitle = scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8)
        let topToSearch = scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8)
        scrollTopToTitle = topToTitle
        scrollTopToSearch = topToSearch
        topToSearch.isActive = false

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),

            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            searchField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            searchHeight,

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            topToTitle,
            scroll.bottomAnchor.constraint(equalTo: settings.topAnchor, constant: -8),

            settings.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            settings.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            settings.heightAnchor.constraint(equalToConstant: 36),
            settings.trailingAnchor.constraint(equalTo: centerXAnchor, constant: -2),

            quit.leadingAnchor.constraint(equalTo: centerXAnchor, constant: 2),
            quit.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            quit.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            quit.heightAnchor.constraint(equalToConstant: 36)
        ])

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: bounds.width > 0 ? bounds.width - 16 : 344)
        ])

        // Warm the app catalog in the background so the first keystroke is snappy.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = AppCatalog.allApps()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Handles navigation / shortcuts while searching. Returns true if the event was consumed.
    @discardableResult
    func handleSearchKeyDown(_ event: NSEvent) -> Bool {
        guard searchVisible else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.keyCode

        // Ctrl+A / Cmd+A — select all search text (Windows-style Ctrl+A included).
        if (flags.contains(.control) || flags.contains(.command))
            && !flags.contains(.option)
            && !flags.contains(.shift)
            && (event.charactersIgnoringModifiers?.lowercased() == "a") {
            selectAllSearchText()
            return true
        }

        // Arrow navigation among results (don't move caret in the field).
        if key == 125 { // Down
            moveSelection(by: 1)
            return true
        }
        if key == 126 { // Up
            moveSelection(by: -1)
            return true
        }

        if key == 36 || key == 76 { // Return / keypad Enter
            _ = launchSelectedResult()
            return true
        }

        if key == 53 { // Escape — exit search back to pinned
            clearSearch()
            return true
        }

        return false
    }

    /// Win10-style: first printable keystroke reveals search and starts filtering.
    func handleTypeToSearch(_ event: NSEvent) -> NSEvent? {
        // Already editing the search field — let it handle input normally.
        if isSearchFieldEditing {
            return event
        }

        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return event }

        // Ignore shortcuts and non-character keys (arrows, tab, return, delete, etc.).
        if event.modifierFlags.contains(.command)
            || event.modifierFlags.contains(.control)
            || event.modifierFlags.contains(.option) {
            return event
        }
        let reserved: Set<UInt16> = [36, 48, 49, 51, 76, 117, 123, 124, 125, 126]
        if reserved.contains(event.keyCode) { return event }
        guard isPrintableSearchStart(chars) else { return event }

        setSearchVisible(true)
        window?.makeFirstResponder(searchField)
        // Deliver this keystroke into the now-focused field.
        return event
    }

    private var isSearchFieldEditing: Bool {
        guard let window else { return false }
        if window.firstResponder === searchField { return true }
        if let editor = window.fieldEditor(false, for: searchField), window.firstResponder === editor {
            return true
        }
        return false
    }

    private func isPrintableSearchStart(_ chars: String) -> Bool {
        chars.contains { char in
            char.isLetter || char.isNumber || char.isPunctuation || char.isSymbol || char == " "
        }
    }

    private func selectAllSearchText() {
        ensureSearchFocused()
        searchField.currentEditor()?.selectAll(nil)
        // Fallback if field editor isn't ready yet.
        if searchField.currentEditor() == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.ensureSearchFocused()
                self.searchField.currentEditor()?.selectAll(nil)
            }
        }
    }

    func clearSearch() {
        guard searchVisible || !searchField.stringValue.isEmpty || selectedIndex >= 0 else {
            rebuildRows(apps: pinnedApps, allowSelection: false)
            return
        }
        selectedIndex = -1
        setSearchVisible(false)
        titleLabel.stringValue = "PINNED"
        if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
        }
        rebuildRows(apps: pinnedApps, allowSelection: false)
        window?.makeFirstResponder(nil)
    }

    @discardableResult
    func launchSelectedResult() -> Bool {
        guard searchVisible, !filteredApps.isEmpty else { return false }
        let index = selectedIndex >= 0 ? selectedIndex : 0
        guard filteredApps.indices.contains(index) else { return false }
        onLaunch?(filteredApps[index].0)
        return true
    }

    private func moveSelection(by delta: Int) {
        guard searchVisible, !filteredApps.isEmpty else { return }
        if selectedIndex < 0 {
            selectedIndex = delta > 0 ? 0 : filteredApps.count - 1
        } else {
            let next = selectedIndex + delta
            selectedIndex = max(0, min(filteredApps.count - 1, next))
        }
        applySelectionHighlight()
        scrollSelectedRowIntoView()
    }

    private func applySelectionHighlight() {
        for (i, row) in resultRows.enumerated() {
            row.setSelected(i == selectedIndex)
        }
    }

    private func scrollSelectedRowIntoView() {
        guard resultRows.indices.contains(selectedIndex) else { return }
        let row = resultRows[selectedIndex]
        let rowFrame = row.convert(row.bounds, to: document)
        scroll.contentView.scrollToVisible(rowFrame)
    }

    private func setSearchVisible(_ visible: Bool) {
        guard searchVisible != visible else {
            if visible { ensureSearchFocused() }
            return
        }
        searchVisible = visible
        searchField.isHidden = !visible
        searchField.alphaValue = visible ? 1 : 0
        searchHeightConstraint?.constant = visible ? 28 : 0
        scrollTopToTitle?.isActive = !visible
        scrollTopToSearch?.isActive = visible
        titleLabel.stringValue = visible ? "APPS" : "PINNED"
        needsLayout = true
        layoutSubtreeIfNeeded()
        if visible {
            ensureSearchFocused()
        }
    }

    private func ensureSearchFocused() {
        guard let window else { return }
        window.makeFirstResponder(searchField)
        if let editor = window.fieldEditor(true, for: searchField) as? NSTextView {
            editor.selectedRange = NSRange(location: searchField.stringValue.count, length: 0)
        }
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        applySearch(query: sender.stringValue)
    }

    func controlTextDidChange(_ obj: Notification) {
        applySearch(query: searchField.stringValue)
    }

    private func applySearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Deleting all text reverts to the normal pinned Start menu.
            if searchVisible {
                clearSearch()
            } else {
                rebuildRows(apps: pinnedApps, allowSelection: false)
            }
            return
        }

        if !searchVisible {
            setSearchVisible(true)
        }
        titleLabel.stringValue = "APPS"

        let lowered = trimmed.lowercased()
        let matches = AppCatalog.allApps().filter { app in
            app.name.lowercased().contains(lowered) || app.bundleID.lowercased().contains(lowered)
        }
        rebuildRows(apps: matches.map { ($0.bundleID, $0.name) }, allowSelection: true)
    }

    private func rebuildRows(apps: [(String, String)], allowSelection: Bool) {
        filteredApps = apps
        resultRows = []
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let rowWidth = bounds.width > 0 ? bounds.width - 16 : 344
        for (bundleID, name) in apps {
            let row = makeRow(bundleID: bundleID, name: name)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
            if allowSelection, let startRow = row as? StartMenuRow {
                resultRows.append(startRow)
            }
        }

        if allowSelection {
            selectedIndex = apps.isEmpty ? -1 : 0
            applySelectionHighlight()
        } else {
            selectedIndex = -1
        }

        if apps.isEmpty && searchVisible && hasSearchQuery {
            let empty = NSTextField(labelWithString: "No apps found")
            empty.font = NSFont.systemFont(ofSize: 13)
            empty.textColor = .secondaryLabelColor
            empty.translatesAutoresizingMaskIntoConstraints = false
            let wrap = NSView()
            wrap.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(empty)
            NSLayoutConstraint.activate([
                wrap.heightAnchor.constraint(equalToConstant: 42),
                empty.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 14),
                empty.centerYAnchor.constraint(equalTo: wrap.centerYAnchor)
            ])
            stack.addArrangedSubview(wrap)
            wrap.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        }

        document.frame = NSRect(
            x: 0,
            y: 0,
            width: rowWidth,
            height: max(CGFloat(max(apps.count, 1)) * 44, 44)
        )
    }

    private static func loadPinnedApps() -> [(String, String)] {
        var apps: [(String, String)] = TaskbarSettings.shared.pinnedBundleIDs.map {
            ($0, PinManager.appName(forBundleID: $0))
        }
        if apps.isEmpty {
            let defaults = [
                "com.google.Chrome",
                "com.apple.finder",
                "com.microsoft.VSCode",
                "com.apple.Terminal",
                "com.tinyspeck.slackmacgap",
                "com.spotify.client"
            ]
            for id in defaults {
                if NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil {
                    apps.append((id, PinManager.appName(forBundleID: id)))
                }
            }
        }
        return apps
    }

    private func makeRow(bundleID: String, name: String) -> NSView {
        let row = StartMenuRow(bundleID: bundleID, name: name)
        row.onClick = { [weak self] id in self?.onLaunch?(id) }
        return row
    }

    private func makeFooterButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.font = NSFont.systemFont(ofSize: 13)
        button.wantsLayer = true
        return button
    }

    @objc private func settingsClicked() { onSettings?() }
    @objc private func quitClicked() { onQuit?() }
}

final class StartMenuRow: NSView {
    let bundleID: String
    var onClick: ((String) -> Void)?
    private var tracking: NSTrackingArea?
    private var isSelected = false
    private var isHovered = false

    init(bundleID: String, name: String) {
        self.bundleID = bundleID
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 42))
        wantsLayer = true

        let icon = NSImageView(frame: NSRect(x: 10, y: 5, width: 32, height: 32))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.image = PinManager.icon(forBundleID: bundleID)
        addSubview(icon)

        let label = NSTextField(labelWithString: name)
        label.font = NSFont.systemFont(ofSize: 14)
        label.textColor = .labelColor
        label.frame = NSRect(x: 52, y: 11, width: 270, height: 20)
        addSubview(label)

        heightAnchor.constraint(equalToConstant: 42).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        refreshHighlight()
    }

    private func refreshHighlight() {
        if isSelected {
            layer?.backgroundColor = NSColor(calibratedRed: 0, green: 0.47, blue: 0.84, alpha: 0.55).cgColor
        } else if isHovered {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshHighlight()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshHighlight()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(bundleID)
    }
}
