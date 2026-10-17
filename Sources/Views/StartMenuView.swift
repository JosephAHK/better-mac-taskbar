import AppKit

final class StartButtonView: NSView {
    var onToggle: (() -> Void)?
    private var tracking: NSTrackingArea?
    private let logo = StartLogoView()
    private var isHighlighted = false
    private var isHovered = false

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
        TaskbarAppearance.addObserver(self, selector: #selector(refreshBackground))
    }

    required init?(coder: NSCoder) { fatalError() }

    func setHighlighted(_ on: Bool) {
        isHighlighted = on
        refreshBackground()
    }

    @objc private func refreshBackground() {
        let color: NSColor
        if isHighlighted {
            color = .controlAccentColor
        } else if isHovered {
            color = NSColor.white.withAlphaComponent(0.12)
        } else {
            color = .clear
        }
        layer?.backgroundColor = resolvedCGColor(color)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBackground()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshBackground()
    }

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Start" }
    override func accessibilityValue() -> Any? { isHighlighted ? "open" : nil }

    override func accessibilityPerformPress() -> Bool {
        onToggle?()
        return true
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

@MainActor
final class StartMenuController {
    private var panel: NSPanel?
    private weak var anchor: NSView?
    private var panelWasVisible = false
    private var localMonitor: Any?
    private var globalMonitor: Any?
    /// True while a submenu (e.g. the power menu) owns the mouse.
    private var suppressDismiss = false
    private lazy var focus = FlyoutFocus { [weak self] in
        self?.hide(restoringFocus: false)
    }

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

    /// `restoringFocus: false` when whatever caused the hide moves focus itself.
    func hide(restoringFocus: Bool = true) {
        let wasVisible = panel != nil
        if wasVisible {
            focus.end(restoringFocus: restoringFocus)
        }
        suppressDismiss = false
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
        DownloadsPanelController.shared.hide()
        TrashPanelController.shared.hide()
        CalendarPanelController.shared.hide()
        // Unhide before measuring the Start button so the menu anchors on-screen
        // when the taskbar was auto-hidden (e.g. Start key).
        if !panelWasVisible {
            panelWasVisible = true
            TaskbarPanelController.shared.beginKeepVisible()
        }

        let width: CGFloat = 360
        let height: CGFloat = 420
        let content = StartMenuView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.onLaunch = { [weak self] bundleID in
            StartLaunchCounts.record(bundleID)
            PinManager.launch(bundleID: bundleID)
            self?.hide(restoringFocus: false)
        }
        content.onReveal = { [weak self] bundleID in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            self?.hide(restoringFocus: false)
        }
        content.onSettings = { [weak self] in
            self?.hide(restoringFocus: false)
            SettingsWindowController.shared.show()
        }
        content.onQuit = {
            AppLog.info("quit requested", ["source": "startMenu"])
            NSApp.terminate(nil)
        }
        content.onPower = { [weak self] action in
            self?.hide(restoringFocus: false)
            // Run after the menu's tracking loop unwinds — alerts and AppleScript
            // misbehave inside it.
            DispatchQueue.main.async {
                guard PowerActionRunner.confirm(action) else { return }
                PowerActionRunner.perform(action)
            }
        }
        content.onMenuSessionChange = { [weak self] active in
            self?.suppressDismiss = active
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
        // Out of full-screen Spaces like the bar it opens from; dark like the bar
        // regardless of the system theme (its text is labelColor on a dark tint).
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = content

        guard let window = view.window else {
            if panelWasVisible {
                TaskbarPanelController.shared.endKeepVisible()
                panelWasVisible = false
            }
            return
        }
        let screenFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
        let x = screenFrame.minX
        let y = screenFrame.maxY
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        focus.begin()
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
        self.anchor = view
        installMonitors()
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
        // A click in another app focuses that app; handing focus back would steal it.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.suppressDismiss else { return }
            self.hide(restoringFocus: false)
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard isVisible, let content = panel?.contentView as? StartMenuView else { return event }
        if content.handleNavigationKeyDown(event) {
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
        guard let panel, !suppressDismiss else { return }
        let location = NSEvent.mouseLocation
        if panel.frame.contains(location) { return }
        // Let the Start button handle its own toggle.
        if let anchor, let window = anchor.window {
            let anchorScreen = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            if anchorScreen.contains(location) { return }
        }
        // A click elsewhere on the taskbar leaves focus on the taskbar, as on Windows —
        // and may be a task button activating its own app.
        hide(restoringFocus: false)
    }
}

struct InstalledApp: Equatable {
    let bundleID: String
    let name: String
}

private extension Notification.Name {
    static let appCatalogChanged = Notification.Name("appCatalogChanged")
}

/// Installed apps for Start search.
///
/// Main-thread only; scans run on a background queue and publish back here. Reads
/// never wait on a scan (stale-while-revalidate): `apps` answers from the last scan,
/// and a rescan runs when an Applications folder changes or, on Start opening, when
/// the last scan is older than `maxAge`. `appCatalogChanged` fires when it lands.
@MainActor
private final class AppCatalog {
    static let shared = AppCatalog()

    private(set) var apps: [InstalledApp] = []
    private var lastScan: Date?
    private var isScanning = false
    private var rescanRequested = false
    private var watchers: [DirectoryWatcher] = []

    /// The watchers only see entries added to or removed from the folders themselves;
    /// this catches what they can't, such as an app replaced inside a subfolder.
    private static let maxAge: TimeInterval = 60

    private nonisolated static let roots: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/System/Applications/Utilities"),
        URL(fileURLWithPath: "/Applications/Utilities"),
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications")
    ]

    private init() {
        watchers = Self.roots.compactMap { root in
            DirectoryWatcher(url: root) { [weak self] in self?.rescan() }
        }
    }

    func refreshIfStale() {
        if let lastScan, Date().timeIntervalSince(lastScan) < Self.maxAge { return }
        rescan()
    }

    private func rescan() {
        guard !isScanning else {
            rescanRequested = true
            return
        }
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let scanned = Self.scanInstalledApps()
            DispatchQueue.main.async {
                self.publish(scanned)
            }
        }
    }

    private func publish(_ scanned: [InstalledApp]) {
        isScanning = false
        lastScan = Date()
        if scanned != apps {
            apps = scanned
            NotificationCenter.default.post(name: .appCatalogChanged, object: nil)
        }
        if rescanRequested {
            rescanRequested = false
            rescan()
        }
    }

    private nonisolated static func scanInstalledApps() -> [InstalledApp] {
        let fm = FileManager.default
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

/// How often each app was launched from Start; breaks ties between equally good
/// search matches so the app you actually use wins Enter.
@MainActor
enum StartLaunchCounts {
    private static let key = "startMenuLaunchCounts"

    static var all: [String: Int] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
    }

    static func record(_ bundleID: String) {
        var counts = all
        counts[bundleID, default: 0] += 1
        UserDefaults.standard.set(counts, forKey: key)
    }
}

/// Start search ranking. Pure — no AppKit, no defaults — so the rules are testable.
enum StartSearchRanker {
    /// Higher is better; nil means no match. Tiers, best first: exact name, name
    /// prefix, prefix of a later word ("code" → Visual Studio Code), initials ("vsc"),
    /// substring, then the bundle ID's last component. The bundle ID is only tried for
    /// 3+ characters and never its vendor prefix, so "com" or "apple" don't match
    /// every app.
    static func score(name: String, bundleID: String, query: String) -> Int? {
        let needle = normalize(query)
        guard !needle.isEmpty else { return nil }
        let folded = normalize(name)
        if folded == needle { return 600 }
        if folded.hasPrefix(needle) { return 500 }

        let words = words(in: name)
        if words.indices.contains(where: { words[$0...].joined(separator: " ").hasPrefix(needle) }) {
            return 400
        }
        if needle.count >= 2, String(words.compactMap(\.first)).hasPrefix(needle) {
            return 300
        }
        if folded.contains(needle) { return 200 }
        if needle.count >= 3,
           let tail = bundleID.split(separator: ".").last,
           normalize(String(tail)).contains(needle) {
            return 100
        }
        return nil
    }

    /// Matches only, best score first; ties go to the more-launched app, then by name.
    static func rank(_ apps: [InstalledApp], query: String, launchCounts: [String: Int]) -> [InstalledApp] {
        apps
            .compactMap { app in score(name: app.name, bundleID: app.bundleID, query: query).map { (app, $0) } }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                let launchesA = launchCounts[a.0.bundleID] ?? 0
                let launchesB = launchCounts[b.0.bundleID] ?? 0
                if launchesA != launchesB { return launchesA > launchesB }
                return a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending
            }
            .map(\.0)
    }

    /// Case-, diacritic- and width-folded, with whitespace runs collapsed to one space.
    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Folded words, split on anything that isn't a letter or digit and at
    /// lower-to-upper camel humps ("TablePlus" → "table", "plus").
    private static func words(in name: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for char in name {
            if !(char.isLetter || char.isNumber) {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                if let previous, previous.isLowercase, char.isUppercase, !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                current.append(char)
            }
            previous = char
        }
        if !current.isEmpty { words.append(current) }
        return words.map(normalize)
    }
}

/// Footer control with a Windows-style hover highlight.
final class StartMenuFooterButton: NSView {
    var onClick: (() -> Void)?

    private var tracking: NSTrackingArea?
    private var isHovered = false
    private let label = NSTextField(labelWithString: "")
    private let iconView = NSImageView()

    init(title: String, symbolName: String? = nil, tooltip: String? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = tooltip

        let content = NSStackView()
        content.orientation = .horizontal
        content.spacing = 6
        content.alignment = .centerY
        content.translatesAutoresizingMaskIntoConstraints = false

        if let symbolName, let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title) {
            iconView.image = image
            iconView.contentTintColor = .secondaryLabelColor
            iconView.translatesAutoresizingMaskIntoConstraints = false
            content.addArrangedSubview(iconView)
            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: 14),
                iconView.heightAnchor.constraint(equalToConstant: 14)
            ])
        }

        if !title.isEmpty {
            label.stringValue = title
            label.font = NSFont.systemFont(ofSize: 13)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            content.addArrangedSubview(label)
        }

        addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Keeps the highlight lit while an attached menu is open.
    var isActive = false {
        didSet { refreshHighlight() }
    }

    private func refreshHighlight() {
        if isHovered || isActive {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(isHovered ? 0.16 : 0.10).cgColor
            label.textColor = .labelColor
            iconView.contentTintColor = .labelColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            label.textColor = .secondaryLabelColor
            iconView.contentTintColor = .secondaryLabelColor
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
        onClick?()
    }
}

final class StartMenuView: NSView, NSSearchFieldDelegate {
    var onLaunch: ((String) -> Void)?
    var onReveal: ((String) -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var onPower: ((PowerAction) -> Void)?
    var onMenuSessionChange: ((Bool) -> Void)?
    var onRequestClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "PINNED")
    private let searchField = NSSearchField()
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let document = NSView()
    private let powerButton = StartMenuFooterButton(title: "", symbolName: "power", tooltip: "Power")

    private var pinnedApps: [(String, String)] = []
    private var filteredApps: [(String, String)] = []
    private var rows: [StartMenuRow] = []
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
        NotificationCenter.default.addObserver(self, selector: #selector(pinnedAppsChanged), name: .pinnedAppsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appCatalogChanged), name: .appCatalogChanged, object: nil)

        let settings = StartMenuFooterButton(title: "Settings", symbolName: "gearshape")
        settings.onClick = { [weak self] in self?.onSettings?() }
        let quit = StartMenuFooterButton(title: "Quit Taskbar", symbolName: "xmark.circle")
        quit.onClick = { [weak self] in self?.onQuit?() }
        let power = powerButton
        power.onClick = { [weak self] in self?.showPowerMenu() }
        addSubview(settings)
        addSubview(quit)
        addSubview(power)

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
            quit.trailingAnchor.constraint(equalTo: power.leadingAnchor, constant: -4),
            quit.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            quit.heightAnchor.constraint(equalToConstant: 36),

            power.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            power.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            power.widthAnchor.constraint(equalToConstant: 40),
            power.heightAnchor.constraint(equalToConstant: 36)
        ])

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: bounds.width > 0 ? bounds.width - 16 : 344)
        ])

        // Rescans in the background if needed; search answers from the last scan meanwhile.
        AppCatalog.shared.refreshIfStale()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Arrow / Enter navigation over the pinned list or search results, plus search
    /// shortcuts. Returns true if the event was consumed.
    @discardableResult
    func handleNavigationKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.keyCode

        // Ctrl+A / Cmd+A — select all search text (Windows-style Ctrl+A included).
        if searchVisible
            && (flags.contains(.control) || flags.contains(.command))
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

        if key == 36 || key == 76 { // Return / keypad Enter; ⌘ shows the app in Finder
            guard let bundleID = selectedBundleID else { return searchVisible }
            if flags.contains(.command) {
                onReveal?(bundleID)
            } else {
                onLaunch?(bundleID)
            }
            return true
        }

        if searchVisible, key == 53 { // Escape — exit search back to pinned
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

    /// Search launches the top result even before an arrow key is pressed; the
    /// pinned list only acts on an explicit selection.
    private var selectedBundleID: String? {
        let index = searchVisible ? max(selectedIndex, 0) : selectedIndex
        return filteredApps.indices.contains(index) ? filteredApps[index].0 : nil
    }

    /// Wraps around at either end, as Windows' Start list does.
    private func moveSelection(by delta: Int) {
        let count = filteredApps.count
        guard count > 0 else { return }
        if selectedIndex < 0 {
            selectedIndex = delta > 0 ? 0 : count - 1
        } else {
            selectedIndex = ((selectedIndex + delta) % count + count) % count
        }
        applySelectionHighlight()
        scrollSelectedRowIntoView()
    }

    private func applySelectionHighlight() {
        for (i, row) in rows.enumerated() {
            row.setSelected(i == selectedIndex)
        }
    }

    private func scrollSelectedRowIntoView() {
        guard rows.indices.contains(selectedIndex) else { return }
        let row = rows[selectedIndex]
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

        let matches = StartSearchRanker.rank(
            AppCatalog.shared.apps,
            query: trimmed,
            launchCounts: StartLaunchCounts.all
        )
        rebuildRows(apps: matches.map { ($0.bundleID, $0.name) }, allowSelection: true)
    }

    @objc private func pinnedAppsChanged() {
        pinnedApps = Self.loadPinnedApps()
        if !searchVisible {
            rebuildRows(apps: pinnedApps, allowSelection: false)
        }
    }

    /// A rescan finished — results typed against the previous catalog may be stale.
    @objc private func appCatalogChanged() {
        if searchVisible {
            applySearch(query: searchField.stringValue)
        }
    }

    /// `allowSelection` preselects the first row (search results, so Enter launches
    /// the best match); the pinned list starts with nothing selected.
    private func rebuildRows(apps: [(String, String)], allowSelection: Bool) {
        filteredApps = apps
        rows = []
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let rowWidth = bounds.width > 0 ? bounds.width - 16 : 344
        for (bundleID, name) in apps {
            let row = makeRow(bundleID: bundleID, name: name)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
            rows.append(row)
        }

        selectedIndex = allowSelection && !apps.isEmpty ? 0 : -1
        applySelectionHighlight()

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

    private func makeRow(bundleID: String, name: String) -> StartMenuRow {
        let row = StartMenuRow(bundleID: bundleID, name: name)
        row.onClick = { [weak self] id in self?.onLaunch?(id) }
        row.onContextMenu = { [weak self, weak row] event in
            guard let self, let row else { return }
            self.showContextMenu(for: bundleID, on: row, with: event)
        }
        return row
    }

    private func showContextMenu(for bundleID: String, on row: StartMenuRow, with event: NSEvent) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let pinTitle = PinManager.isPinned(bundleID) ? "Unpin from taskbar" : "Pin to taskbar"
        menu.addItem(StartMenuActionItem(title: pinTitle) {
            PinManager.togglePin(bundleID: bundleID)
        })
        menu.addItem(StartMenuActionItem(title: "Show in Finder") { [weak self] in
            self?.onReveal?(bundleID)
        })
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if !running.isEmpty {
            menu.addItem(.separator())
            menu.addItem(StartMenuActionItem(title: "Quit") {
                running.forEach { $0.terminate() }
            })
        }

        // Same as the power menu: the menu's tracking loop must not trip outside-click dismissal.
        onMenuSessionChange?(true)
        NSMenu.popUpContextMenu(menu, with: event, for: row)
        onMenuSessionChange?(false)
    }

    private func showPowerMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for action in PowerAction.allCases {
            let item = NSMenuItem(title: action.title, action: #selector(powerItemClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = PowerActionBox(action)
            item.image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: action.title)
            menu.addItem(item)
        }

        powerButton.isActive = true
        // NSMenu runs its own tracking loop — suppress the outside-click dismissal so
        // the Start panel isn't torn down underneath the menu.
        onMenuSessionChange?(true)
        let origin = NSPoint(x: 0, y: powerButton.bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: powerButton)
        onMenuSessionChange?(false)
        powerButton.isActive = false
    }

    @objc private func powerItemClicked(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? PowerActionBox else { return }
        onPower?(box.action)
    }
}

/// NSMenuItem.representedObject needs a class type — PowerAction is an enum.
private final class PowerActionBox: NSObject {
    let action: PowerAction
    init(_ action: PowerAction) { self.action = action }
}

/// Menu item that runs a closure, for the per-row context menu.
private final class StartMenuActionItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() {
        handler()
    }
}

final class StartMenuRow: NSView {
    let bundleID: String
    var onClick: ((String) -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
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
            layer?.backgroundColor = resolvedCGColor(NSColor.controlAccentColor.withAlphaComponent(0.55))
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
        // ⌃-click is a right-click on a Mac trackpad or one-button mouse.
        if event.modifierFlags.contains(.control) {
            onContextMenu?(event)
        } else {
            onClick?(bundleID)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(event)
    }
}
