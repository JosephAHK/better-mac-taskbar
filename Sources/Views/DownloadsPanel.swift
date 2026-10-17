import AppKit

/// Taskbar Downloads button — opens a Finder-like list you can drag files out of.
final class DownloadsButtonView: TrayItemButtonView {
    init() {
        super.init(title: "Downloads")

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if let downloads {
            iconView.image = NSWorkspace.shared.icon(forFile: downloads.path)
        } else {
            iconView.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "Downloads")
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Borderless panels refuse key status by default — search needs a key window.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DownloadsPanelController {
    static let shared = DownloadsPanelController()

    private var panel: NSPanel?
    private weak var anchor: NSView?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var isDraggingFile = false
    private lazy var focus = FlyoutFocus { [weak self] in
        self?.hide(restoringFocus: false)
    }

    var isVisible: Bool { panel?.isVisible == true }

    private init() {}

    func toggle(relativeTo view: NSView) {
        if isVisible, anchor === view {
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
        TrashPanelController.shared.hide()
        CalendarPanelController.shared.hide()
        hide()
        guard let window = view.window else { return }

        let width: CGFloat = 340
        let height: CGFloat = 420
        let content = DownloadsPanelView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.onOpenInFinder = { [weak self] url in
            NSWorkspace.shared.open(url)
            self?.hide(restoringFocus: false)
        }
        content.onFileOpened = { [weak self] in
            self?.hide(restoringFocus: false)
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
        // Out of full-screen Spaces like the bar it opens from; dark like the bar
        // regardless of the system theme (its text is labelColor on a dark tint).
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = content

        let screenFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
        let x = min(max(screenFrame.maxX - width, screenFrame.minX), (window.screen?.visibleFrame.maxX ?? screenFrame.maxX) - width)
        let y = screenFrame.maxY + 2
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)

        focus.begin()
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
        // A click in another app focuses that app; handing focus back would steal it.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.isDraggingFile else { return }
            self.hide(restoringFocus: false)
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard isVisible, let content = panel?.contentView as? DownloadsPanelView else { return event }
        if event.keyCode == 53 { // Escape
            // Handled here rather than by the search field, which only sees it while focused.
            content.handleEscape()
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
        // A click elsewhere on the taskbar leaves focus on the taskbar, as on Windows —
        // and may be a task button activating its own app.
        hide(restoringFocus: false)
    }
}

final class DownloadsPanelView: NSView, NSSearchFieldDelegate {
    var onOpenInFinder: ((URL) -> Void)?
    var onFileOpened: (() -> Void)?
    var onRequestClose: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Downloads")
    private let backButton = NSButton()
    private let searchField = NSSearchField()
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let loader = FolderLoader()
    private var folderWatcher: DirectoryWatcher?
    /// Nil until the current folder's first listing arrives, so a folder that is
    /// still loading doesn't flash "empty".
    private var listing: [FolderEntry]?
    private var filteredFiles: [FolderEntry] = []
    private var rowCache = FolderRowCache<DownloadsFileRow>()
    private lazy var currentURL: URL = downloadsURL()
    private var backStack: [URL] = []
    private var isAtRoot: Bool { backStack.isEmpty }

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

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        backButton.bezelStyle = .inline
        backButton.isBordered = false
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.toolTip = "Back"
        backButton.isHidden = true
        backButton.translatesAutoresizingMaskIntoConstraints = false

        let headerStack = NSStackView(views: [backButton, titleLabel])
        headerStack.orientation = .horizontal
        headerStack.spacing = 6
        headerStack.alignment = .centerY
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let openButton = NSButton(title: "Open in Finder", target: self, action: #selector(openFinder))
        openButton.bezelStyle = .inline
        openButton.isBordered = false
        openButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        openButton.contentTintColor = .controlAccentColor
        openButton.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search downloads"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(headerStack)
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
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            headerStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            headerStack.trailingAnchor.constraint(lessThanOrEqualTo: openButton.leadingAnchor, constant: -8),
            backButton.widthAnchor.constraint(equalToConstant: 14),

            openButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            openButton.centerYAnchor.constraint(equalTo: headerStack.centerYAnchor),

            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            searchField.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 10),
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

    @objc private func openFinder() {
        onOpenInFinder?(currentURL)
    }

    @objc private func goBack() {
        guard let previous = backStack.popLast() else { return }
        show(folder: previous)
    }

    /// Escape steps out one level at a time: clear the search, then go back up a
    /// folder, and only close from the top level.
    func handleEscape() {
        if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            applyFilter()
        } else if !isAtRoot {
            goBack()
        } else {
            onRequestClose?()
        }
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        applyFilter()
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(cancelOperation(_:)) {
            handleEscape()
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
        activate(first)
    }

    /// Navigate into a folder in-place, or open a file with its default app.
    private func activate(_ entry: FolderEntry) {
        if entry.isDirectory {
            navigate(to: entry.url)
        } else {
            NSWorkspace.shared.open(entry.url)
            onFileOpened?()
        }
    }

    private func navigate(to url: URL) {
        backStack.append(currentURL)
        show(folder: url)
    }

    private func show(folder url: URL) {
        currentURL = url
        searchField.stringValue = ""
        listing = nil
        updateHeader()
        applyFilter()
        reloadFromDisk()
        startWatching()
    }

    private func updateHeader() {
        titleLabel.stringValue = isAtRoot ? "Downloads" : currentURL.lastPathComponent
        backButton.isHidden = isAtRoot
    }

    private func delete(_ entry: FolderEntry) {
        var resultingItemURL: NSURL?
        do {
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: &resultingItemURL)
            if let trashedURL = resultingItemURL as URL? {
                TrashOriginStore.record(trashedURL: trashedURL, originalURL: entry.url)
            }
        } catch {
            ErrorAlert.show(
                title: "Couldn’t Move “\(entry.url.lastPathComponent)” to the Trash",
                message: error.localizedDescription
            )
        }
        reloadFromDisk()
    }

    private func downloadsURL() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    private func reloadFromDisk() {
        loader.load(currentURL) { [weak self] result in
            guard let self else { return }
            self.listing = (try? result.get()) ?? []
            self.applyFilter()
        }
    }

    private func applyFilter() {
        guard let listing else {
            filteredFiles = []
            FolderList.setRows([], in: stack)
            return
        }

        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredFiles = FolderList.filter(listing, query: query)
        let rowWidth = max(bounds.width - 16, 300)

        if filteredFiles.isEmpty {
            let message = listing.isEmpty
                ? (isAtRoot ? "No downloads yet" : "This folder is empty")
                : "No matches"
            FolderList.setRows([rowCache.messageRow(message, width: rowWidth)], in: stack)
            return
        }

        let displayed = Array(filteredFiles.prefix(FolderList.displayLimit))
        var rows: [NSView] = rowCache.rows(for: displayed) { makeRow(for: $0, width: rowWidth) }
        if filteredFiles.count > displayed.count {
            let overflow = FolderList.overflowText(hiddenCount: filteredFiles.count - displayed.count)
            rows.append(rowCache.messageRow(overflow, width: rowWidth, height: 36))
        }
        FolderList.setRows(rows, in: stack)
    }

    private func makeRow(for entry: FolderEntry, width: CGFloat) -> DownloadsFileRow {
        let row = DownloadsFileRow(entry: entry, width: width)
        row.onOpen = { [weak self] in
            self?.activate(entry)
        }
        row.onReveal = {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        }
        row.onDelete = { [weak self] in
            self?.delete(entry)
        }
        row.onDragBegan = { [weak self] in self?.onDragBegan?() }
        row.onDragEnded = { [weak self] in self?.onDragEnded?() }
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    private func startWatching() {
        folderWatcher = DirectoryWatcher(url: currentURL) { [weak self] in
            self?.reloadFromDisk()
        }
    }
}

private final class DownloadsFileRow: NSView, NSDraggingSource {
    let url: URL
    let isDirectory: Bool
    var onOpen: (() -> Void)?
    var onReveal: (() -> Void)?
    var onDelete: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?

    private let deleteButton = NSButton()
    private let iconView = NSImageView()
    private var thumbnailRequest: Operation?
    private var tracking: NSTrackingArea?
    private var mouseDownPoint: NSPoint?
    private var didStartDrag = false

    init(entry: FolderEntry, width: CGFloat) {
        self.url = entry.url
        self.isDirectory = entry.isDirectory
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 40))
        wantsLayer = true
        layer?.cornerRadius = 4

        iconView.frame = NSRect(x: 8, y: 6, width: 28, height: 28)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = NSWorkspace.shared.icon(forFile: url.path)
        addSubview(iconView)
        if !entry.isDirectory, ImageThumbnailer.isImage(url) {
            thumbnailRequest = ImageThumbnailer.thumbnail(for: url, modified: entry.modified, maxPixelSize: 56) { [weak iconView] image in
                iconView?.image = image
            }
        }

        // Everything right-aligned is inset by the scroller gutter — see PanelMetrics.
        let gutter = PanelMetrics.scrollerGutter
        let nameWidth = width - 56 - gutter - (entry.isDirectory ? 18 : 0) - 24
        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = NSFont.systemFont(ofSize: 13)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingMiddle
        name.frame = NSRect(x: 44, y: 10, width: max(nameWidth, 60), height: 20)
        addSubview(name)

        if entry.isDirectory {
            let chevron = NSImageView(frame: NSRect(x: width - 48 - gutter, y: 13, width: 14, height: 14))
            chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Open folder")
            chevron.contentTintColor = .tertiaryLabelColor
            chevron.imageScaling = .scaleProportionallyUpOrDown
            addSubview(chevron)
        }

        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
        deleteButton.bezelStyle = .inline
        deleteButton.isBordered = false
        deleteButton.contentTintColor = .secondaryLabelColor
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.isHidden = true
        deleteButton.frame = NSRect(x: width - 26 - gutter, y: 9, width: 22, height: 22)
        addSubview(deleteButton)

        heightAnchor.constraint(equalToConstant: 40).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A row leaves its window when the list drops it or the panel closes; its
    /// thumbnail is no longer worth decoding.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            thumbnailRequest?.cancel()
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
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        deleteButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
        deleteButton.isHidden = true
    }

    @objc private func deleteTapped() {
        onDelete?()
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
            onReveal?()
        } else {
            onOpen?()
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
