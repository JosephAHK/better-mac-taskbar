import AppKit

/// Taskbar Trash button — browse, restore, or empty the Trash without opening Finder.
final class TrashButtonView: TrayItemButtonView {
    /// Keeps the can's full/empty state live when Finder (or anything else) changes
    /// the Trash. Nil if ~/.Trash can't be opened; the icon then still refreshes on hover.
    private var trashWatcher: DirectoryWatcher?

    init() {
        super.init(title: "Trash")
        refreshIcon()
        trashWatcher = DirectoryWatcher(url: TrashPanelView.trashRootURL()) { [weak self] in
            self?.refreshIcon()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The system trash can, empty or full to match the real Trash.
    ///
    /// `NSWorkspace.icon(forFile:)` on ~/.Trash returns a generic folder icon, not a
    /// trash can, so the named system images are used instead — they are the same
    /// artwork the Dock uses.
    override func refreshIcon() {
        let name = Self.isTrashEmpty() ? NSImage.trashEmptyName : NSImage.trashFullName
        iconView.image = NSImage(named: name)
    }

    /// Stops at the first visible item — this runs on every Trash change and hover,
    /// and listing a large Trash in full each time would stall the main thread.
    private static func isTrashEmpty() -> Bool {
        let enumerator = FileManager.default.enumerator(
            at: TrashPanelView.trashRootURL(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            // Unreadable Trash reads as empty: showing a full can for a folder we cannot
            // enumerate would be a permanent false positive.
            errorHandler: { _, _ in false }
        )
        return enumerator?.nextObject() == nil
    }
}

/// Borderless panels refuse key status by default — search needs a key window.
private final class TrashKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class TrashPanelController {
    static let shared = TrashPanelController()

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
        if let button = anchor as? TrashButtonView {
            button.isOpen = false
        }
        anchor = nil
        isDraggingFile = false
        if wasVisible {
            TaskbarPanelController.shared.endKeepVisible()
        }
    }

    private func show(relativeTo view: NSView) {
        DownloadsPanelController.shared.hide()
        CalendarPanelController.shared.hide()
        hide()
        guard let window = view.window else { return }

        let width: CGFloat = 340
        let height: CGFloat = 420
        let content = TrashPanelView(frame: NSRect(x: 0, y: 0, width: width, height: height))
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

        let panel = TrashKeyablePanel(
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
        DispatchQueue.main.async {
            content.focusSearch()
        }

        self.panel = panel
        self.anchor = view
        if let button = view as? TrashButtonView {
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
        guard isVisible, let content = panel?.contentView as? TrashPanelView else { return event }
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

final class TrashPanelView: NSView, NSSearchFieldDelegate {
    var onOpenInFinder: ((URL) -> Void)?
    var onFileOpened: (() -> Void)?
    var onRequestClose: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Trash")
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
    private var rowCache = FolderRowCache<TrashFileRow>()
    private var needsFullDiskAccess = false
    private var isEmptying = false
    private lazy var currentURL: URL = Self.trashRootURL()
    private var backStack: [URL] = []
    private var isAtRoot: Bool { backStack.isEmpty }

    static func trashRootURL() -> URL {
        (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
    }

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
        backButton.isHidden = true
        backButton.translatesAutoresizingMaskIntoConstraints = false

        let headerStack = NSStackView(views: [backButton, titleLabel])
        headerStack.orientation = .horizontal
        headerStack.spacing = 6
        headerStack.alignment = .centerY
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let emptyButton = NSButton(title: "Empty", target: self, action: #selector(emptyTapped))
        emptyButton.bezelStyle = .inline
        emptyButton.isBordered = false
        emptyButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        emptyButton.contentTintColor = .systemRed
        emptyButton.translatesAutoresizingMaskIntoConstraints = false

        let openButton = NSButton(title: "Finder", target: self, action: #selector(openFinder))
        openButton.bezelStyle = .inline
        openButton.isBordered = false
        openButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        openButton.contentTintColor = .controlAccentColor
        openButton.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search trash"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(headerStack)
        addSubview(emptyButton)
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
            headerStack.trailingAnchor.constraint(lessThanOrEqualTo: emptyButton.leadingAnchor, constant: -8),
            backButton.widthAnchor.constraint(equalToConstant: 14),

            openButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            openButton.centerYAnchor.constraint(equalTo: headerStack.centerYAnchor),

            emptyButton.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -10),
            emptyButton.centerYAnchor.constraint(equalTo: headerStack.centerYAnchor),

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

    @objc private func emptyTapped() {
        let alert = NSAlert()
        alert.messageText = "Empty Trash?"
        alert.informativeText = "This will permanently erase the items in the Trash. This can’t be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        if #available(macOS 11.0, *) {
            alert.buttons.first?.hasDestructiveAction = true
        }
        guard !isEmptying, alert.runModal() == .alertFirstButtonReturn else { return }

        // osascript in a child process rather than NSAppleScript: NSAppleScript is only
        // safe on the main thread, and the Apple event can block for as long as Finder
        // takes to answer (up to the 2-minute AppleScript timeout), freezing the taskbar.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"Finder\" to empty trash"]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            let stderr = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async { [weak self] in
                self?.finishEmptying(status: status, stderr: stderr)
            }
        }
        do {
            try process.run()
            isEmptying = true
        } catch {
            ErrorAlert.show(title: "Couldn’t Empty the Trash", message: error.localizedDescription)
        }
    }

    private func finishEmptying(status: Int32, stderr: String) {
        isEmptying = false
        guard status == 0 else {
            // osascript reports failures as "…: <message> (<code>)" on stderr.
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let code = message.range(of: #"\((-?\d+)\)$"#, options: .regularExpression)
                .flatMap { Int(message[$0].dropFirst().dropLast()) }
            AppLog.info("empty trash failed", ["status": status, "error": message])
            ErrorAlert.showAppleScriptFailure(
                title: "Couldn’t Empty the Trash",
                targetApp: "Finder",
                code: code,
                message: message.isEmpty ? "Finder didn’t empty the Trash." : message
            )
            return
        }
        let root = Self.trashRootURL()
        TrashOriginStore.removeAll(under: root)
        backStack.removeAll()
        show(folder: root)
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
        titleLabel.stringValue = isAtRoot ? "Trash" : currentURL.lastPathComponent
        backButton.isHidden = isAtRoot
    }

    /// Restore only works reliably for items this app itself trashed (tracked origin) —
    /// items Finder trashed (or trashed before this store existed) have no known origin,
    /// so we tell the user rather than guessing a destination.
    private func restore(_ entry: FolderEntry) {
        let name = entry.url.lastPathComponent
        let original: URL
        switch TrashOriginStore.origin(for: entry.url) {
        case .verified(let url):
            original = url
        case .unverified(let url):
            guard confirmUnverifiedRestore(name: name, to: url.deletingLastPathComponent()) else { return }
            original = url
        case nil:
            ErrorAlert.show(
                title: "Can’t Restore “\(name)”",
                message: "Better Mac Taskbar doesn’t know where this item was trashed from. Use Finder’s Trash (right-click → Put Back) instead."
            )
            return
        }

        let fm = FileManager.default
        let parent = original.deletingLastPathComponent()
        guard fm.fileExists(atPath: parent.path) else {
            ErrorAlert.show(title: "Can’t Restore “\(name)”", message: "Its original folder no longer exists.")
            return
        }
        let destination = Self.availableRestoreURL(for: original)
        do {
            try fm.moveItem(at: entry.url, to: destination)
            TrashOriginStore.remove(trashedURL: entry.url)
            reloadFromDisk()
        } catch {
            ErrorAlert.show(title: "Couldn’t Restore “\(name)”", message: error.localizedDescription)
        }
    }

    /// Origins recorded by older versions carry no file identity, so the record may
    /// belong to an earlier item with the same name that has since been emptied.
    private func confirmUnverifiedRestore(name: String, to folder: URL) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Restore “\(name)” to “\(folder.lastPathComponent)”?"
        alert.informativeText = "An item with this name was trashed from \(folder.path), but Better Mac Taskbar can’t confirm it’s this one."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Extensions that read as one unit, so `a.tar.gz` becomes `a (Restored).tar.gz`.
    private static let compoundExtensions = ["tar.gz", "tar.bz2", "tar.xz"]

    /// `original` if free, else "name (Restored).ext", "name (Restored 2).ext", …
    private static func availableRestoreURL(for original: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: original.path) else { return original }

        let parent = original.deletingLastPathComponent()
        let fileName = original.lastPathComponent
        let lowered = fileName.lowercased()
        let ext = compoundExtensions.first { lowered.hasSuffix(".\($0)") && lowered.count > $0.count + 1 }
            .map { String(fileName.suffix($0.count)) }
            ?? original.pathExtension
        let base = ext.isEmpty ? fileName : String(fileName.dropLast(ext.count + 1))

        var attempt = 1
        while true {
            let suffix = attempt == 1 ? " (Restored)" : " (Restored \(attempt))"
            let candidateName = ext.isEmpty ? base + suffix : "\(base)\(suffix).\(ext)"
            let candidate = parent.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            attempt += 1
        }
    }

    private func reloadFromDisk() {
        loader.load(currentURL) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let entries):
                self.needsFullDiskAccess = false
                self.listing = entries
            case .failure(let error):
                // ~/.Trash is TCC-protected — without Full Disk Access this throws
                // NSFileReadNoPermissionError and would otherwise look like "Trash is empty".
                self.needsFullDiskAccess = (error as NSError).code == NSFileReadNoPermissionError
                self.listing = []
            }
            self.applyFilter()
        }
    }

    @objc private func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
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

        if needsFullDiskAccess {
            FolderList.setRows([fullDiskAccessMessage], in: stack)
            return
        }

        if filteredFiles.isEmpty {
            let message = listing.isEmpty
                ? (isAtRoot ? "Trash is empty" : "This folder is empty")
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

    private func makeRow(for entry: FolderEntry, width: CGFloat) -> TrashFileRow {
        let row = TrashFileRow(entry: entry, width: width, allowsRestore: isAtRoot)
        row.onOpen = { [weak self] in
            self?.activate(entry)
        }
        row.onReveal = {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        }
        row.onRestore = { [weak self] in
            self?.restore(entry)
        }
        row.onDragBegan = { [weak self] in self?.onDragBegan?() }
        row.onDragEnded = { [weak self] in self?.onDragEnded?() }
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    private lazy var fullDiskAccessMessage: NSView = makeFullDiskAccessMessage()

    private func makeFullDiskAccessMessage() -> NSView {
        let message = NSTextField(wrappingLabelWithString: "Better Mac Taskbar needs Full Disk Access to show what’s in the Trash.")
        message.font = NSFont.systemFont(ofSize: 13)
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        message.translatesAutoresizingMaskIntoConstraints = false

        let openSettings = NSButton(
            title: "Open Full Disk Access Settings…",
            target: self,
            action: #selector(openFullDiskAccessSettings)
        )
        openSettings.bezelStyle = .inline
        openSettings.isBordered = false
        openSettings.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        openSettings.contentTintColor = .controlAccentColor
        openSettings.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [message, openSettings])
        column.orientation = .vertical
        column.spacing = 10
        column.alignment = .centerX
        column.translatesAutoresizingMaskIntoConstraints = false

        let rowWidth = max(bounds.width - 16, 300)
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(column)
        NSLayoutConstraint.activate([
            wrap.widthAnchor.constraint(equalToConstant: rowWidth),
            wrap.heightAnchor.constraint(equalToConstant: 140),
            column.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            column.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            message.widthAnchor.constraint(equalToConstant: rowWidth - 32)
        ])
        return wrap
    }

    private func startWatching() {
        folderWatcher = DirectoryWatcher(url: currentURL) { [weak self] in
            self?.reloadFromDisk()
        }
    }
}

private final class TrashFileRow: NSView, NSDraggingSource {
    let url: URL
    let isDirectory: Bool
    var onOpen: (() -> Void)?
    var onReveal: (() -> Void)?
    var onRestore: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?

    private let restoreButton = NSButton()
    private let iconView = NSImageView()
    private let allowsRestore: Bool
    private var thumbnailRequest: Operation?
    private var tracking: NSTrackingArea?
    private var mouseDownPoint: NSPoint?
    private var didStartDrag = false

    init(entry: FolderEntry, width: CGFloat, allowsRestore: Bool) {
        self.url = entry.url
        self.isDirectory = entry.isDirectory
        self.allowsRestore = allowsRestore
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
        let nameWidth = width - 56 - gutter - (entry.isDirectory ? 18 : 0) - (allowsRestore ? 24 : 0)
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

        if allowsRestore {
            restoreButton.image = NSImage(systemSymbolName: "arrow.up.bin", accessibilityDescription: "Restore")
            restoreButton.bezelStyle = .inline
            restoreButton.isBordered = false
            restoreButton.contentTintColor = .secondaryLabelColor
            restoreButton.target = self
            restoreButton.action = #selector(restoreTapped)
            restoreButton.isHidden = true
            restoreButton.frame = NSRect(x: width - 26 - gutter, y: 9, width: 22, height: 22)
            addSubview(restoreButton)
        }

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
        if allowsRestore { restoreButton.isHidden = false }
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
        if allowsRestore { restoreButton.isHidden = true }
    }

    @objc private func restoreTapped() {
        onRestore?()
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
