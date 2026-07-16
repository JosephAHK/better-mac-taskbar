import AppKit

/// Taskbar Downloads button — opens a Finder-like list you can drag files out of.
final class DownloadsButtonView: NSView {
    var onToggle: (() -> Void)?
    var isOpen = false {
        didSet { refreshAppearance() }
    }

    private let iconView = NSImageView()
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        toolTip = "Downloads"

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if let downloads {
            iconView.image = NSWorkspace.shared.icon(forFile: downloads.path)
        } else {
            iconView.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "Downloads")
        }

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refreshAppearance() {
        if isOpen {
            layer?.backgroundColor = NSColor(calibratedRed: 0, green: 0.47, blue: 0.84, alpha: 1).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) {
        if !isOpen {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        refreshAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }
}

/// Borderless panels refuse key status by default — search needs a key window.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class DownloadsPanelController {
    static let shared = DownloadsPanelController()

    private var panel: NSPanel?
    private weak var anchor: NSView?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var isDraggingFile = false

    var isVisible: Bool { panel?.isVisible == true }

    private init() {}

    func toggle(relativeTo view: NSView) {
        if isVisible, anchor === view {
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
        if let button = anchor as? DownloadsButtonView {
            button.isOpen = false
        }
        anchor = nil
        isDraggingFile = false
        if wasVisible {
            TaskbarPanelController.shared.endKeepVisible()
        }
    }

    private func show(relativeTo view: NSView) {
        VolumePanelController.shared.hide()
        WiFiPanelController.shared.hide()
        hide()
        guard let window = view.window else { return }

        let width: CGFloat = 340
        let height: CGFloat = 420
        let content = DownloadsPanelView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.onOpenInFinder = { [weak self] in
            let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
            NSWorkspace.shared.open(url)
            self?.hide()
        }
        content.onFileOpened = { [weak self] in
            self?.hide()
        }
        content.onRequestClose = { [weak self] in
            self?.hide()
        }
        content.onDragBegan = { [weak self] in
            self?.isDraggingFile = true
        }
        content.onDragEnded = { [weak self] in
            self?.isDraggingFile = false
        }

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.worksWhenModal = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = content

        let screenFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
        let x = min(max(screenFrame.maxX - width, screenFrame.minX), (window.screen?.visibleFrame.maxX ?? screenFrame.maxX) - width)
        let y = screenFrame.maxY + 2
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)

        // Accessory (LSUIElement) apps must activate before a panel can take keyboard focus.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Defer so the run loop finishes making the panel key first.
        DispatchQueue.main.async {
            content.focusSearch()
        }

        self.panel = panel
        self.anchor = view
        if let button = view as? DownloadsButtonView {
            button.isOpen = true
        }
        installMonitors()
        TaskbarPanelController.shared.beginKeepVisible()
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
            guard let self, !self.isDraggingFile else { return }
            self.hide()
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard isVisible else { return event }
        if event.keyCode == 53 { // Escape
            // Let the search field clear its query first; only close when empty.
            if let content = panel?.contentView as? DownloadsPanelView, content.hasSearchQuery {
                return event
            }
            hide()
            return nil
        }
        return event
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
        guard !isDraggingFile, let panel else { return }
        let location = NSEvent.mouseLocation
        if panel.frame.contains(location) { return }
        if let anchor, let window = anchor.window {
            let anchorScreen = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            if anchorScreen.contains(location) { return }
        }
        hide()
    }
}

final class DownloadsPanelView: NSView, NSSearchFieldDelegate {
    var onOpenInFinder: (() -> Void)?
    var onFileOpened: (() -> Void)?
    var onRequestClose: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?

    private let searchField = NSSearchField()
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var folderWatcher: DispatchSourceFileSystemObject?
    private var folderFD: Int32 = -1
    private var allFiles: [URL] = []
    private var filteredFiles: [URL] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        let effect = NSVisualEffectView(frame: bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        addSubview(effect, positioned: .below, relativeTo: nil)

        let tint = NSView(frame: bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        addSubview(tint, positioned: .above, relativeTo: effect)

        let title = NSTextField(labelWithString: "Downloads")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        let openButton = NSButton(title: "Open in Finder", target: self, action: #selector(openFinder))
        openButton.bezelStyle = .inline
        openButton.isBordered = false
        openButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        openButton.contentTintColor = NSColor(calibratedRed: 0.35, green: 0.72, blue: 1, alpha: 1)
        openButton.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search downloads"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(title)
        addSubview(openButton)
        addSubview(searchField)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4),
            stack.widthAnchor.constraint(equalTo: document.widthAnchor)
        ])
        scroll.documentView = document

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 12),

            openButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            openButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            searchField.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            searchField.heightAnchor.constraint(equalToConstant: 28),

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            document.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -4)
        ])

        reloadFromDisk()
        startWatching()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        stopWatching()
    }

    func focusSearch() {
        guard let window else { return }
        window.makeKey()
        window.makeFirstResponder(searchField)
        // Select any existing text so typing replaces it immediately.
        if let editor = window.fieldEditor(true, for: searchField) as? NSTextView {
            editor.selectAll(nil)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    var hasSearchQuery: Bool {
        !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc private func openFinder() {
        onOpenInFinder?()
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        applyFilter()
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(cancelOperation(_:)) {
            if !searchField.stringValue.isEmpty {
                searchField.stringValue = ""
                applyFilter()
            } else {
                onRequestClose?()
            }
            return true
        }
        if commandSelector == #selector(insertNewline(_:)) {
            openFirstResult()
            return true
        }
        return false
    }

    private func openFirstResult() {
        guard let first = filteredFiles.first else { return }
        NSWorkspace.shared.open(first)
        onFileOpened?()
    }

    private func downloadsURL() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    private func reloadFromDisk() {
        let url = downloadsURL()
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .nameKey]
        let files = (try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        allFiles = files.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        applyFilter()
    }

    private func applyFilter() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filteredFiles = allFiles
        } else {
            let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
            filteredFiles = allFiles.filter { url in
                let name = url.lastPathComponent
                return tokens.allSatisfy { name.localizedCaseInsensitiveContains($0) }
            }
        }

        if filteredFiles.isEmpty {
            let message = allFiles.isEmpty ? "No downloads yet" : "No matches"
            let empty = NSTextField(labelWithString: message)
            empty.font = NSFont.systemFont(ofSize: 13)
            empty.textColor = .secondaryLabelColor
            empty.alignment = .center
            empty.translatesAutoresizingMaskIntoConstraints = false
            let wrap = NSView()
            wrap.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(empty)
            NSLayoutConstraint.activate([
                wrap.heightAnchor.constraint(equalToConstant: 80),
                empty.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
                empty.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
                wrap.widthAnchor.constraint(equalToConstant: bounds.width - 16)
            ])
            stack.addArrangedSubview(wrap)
            return
        }

        // Cap the unfiltered list for responsiveness; show every match when searching.
        let displayed = query.isEmpty ? Array(filteredFiles.prefix(150)) : filteredFiles
        let rowWidth = max(bounds.width - 16, 300)
        for fileURL in displayed {
            let row = DownloadsFileRow(url: fileURL, width: rowWidth)
            row.onOpen = { [weak self] url in
                NSWorkspace.shared.open(url)
                self?.onFileOpened?()
            }
            row.onReveal = { url in
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            row.onDragBegan = { [weak self] in self?.onDragBegan?() }
            row.onDragEnded = { [weak self] in self?.onDragEnded?() }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        }
    }

    private func startWatching() {
        stopWatching()
        let path = downloadsURL().path
        folderFD = open(path, O_EVTONLY)
        guard folderFD >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: folderFD,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.reloadFromDisk()
        }
        source.setCancelHandler { [weak self] in
            if let self, self.folderFD >= 0 {
                close(self.folderFD)
                self.folderFD = -1
            }
        }
        folderWatcher = source
        source.resume()
    }

    private func stopWatching() {
        folderWatcher?.cancel()
        folderWatcher = nil
    }
}

private final class DownloadsFileRow: NSView, NSDraggingSource {
    let url: URL
    var onOpen: ((URL) -> Void)?
    var onReveal: ((URL) -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?

    private var tracking: NSTrackingArea?
    private var mouseDownPoint: NSPoint?
    private var didStartDrag = false

    init(url: URL, width: CGFloat) {
        self.url = url
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 40))
        wantsLayer = true
        layer?.cornerRadius = 4
        toolTip = "Double-click to open · ⌘-double-click to reveal in Finder · Drag to copy"

        let icon = NSImageView(frame: NSRect(x: 8, y: 4, width: 28, height: 28))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.image = NSWorkspace.shared.icon(forFile: url.path)
        addSubview(icon)

        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = NSFont.systemFont(ofSize: 13)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingMiddle
        name.toolTip = url.path
        name.frame = NSRect(x: 44, y: 10, width: width - 56, height: 20)
        addSubview(name)

        heightAnchor.constraint(equalToConstant: 40).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !didStartDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = abs(point.x - start.x)
        let dy = abs(point.y - start.y)
        guard dx >= 4 || dy >= 4 else { return }

        didStartDrag = true
        onDragBegan?()

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(
            NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32),
            contents: NSWorkspace.shared.icon(forFile: url.path)
        )
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            didStartDrag = false
        }
        guard !didStartDrag else { return }
        // Finder-style: open on double-click only (single-click is for drag/select).
        guard event.clickCount >= 2 else { return }
        if event.modifierFlags.contains(.command) {
            onReveal?(url)
        } else {
            onOpen?(url)
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link] : [.copy]
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        onDragEnded?()
    }
}
