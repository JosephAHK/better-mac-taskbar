import AppKit

/// Taskbar Trash button — browse, restore, or empty the Trash without opening Finder.
final class TrashButtonView: NSView {
    var onToggle: (() -> Void)?
    var isOpen = false {
        didSet { refreshAppearance() }
    }

    private let iconView = NSImageView()
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        toolTip = "Trash"

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        refreshIcon()

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The Finder-provided icon reflects full/empty state automatically.
    func refreshIcon() {
        iconView.image = NSWorkspace.shared.icon(forFile: TrashPanelView.trashRootURL().path)
    }

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
        refreshIcon()
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
private final class TrashKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class TrashPanelController {
    static let shared = TrashPanelController()

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
        hide()
        guard let window = view.window else {
            AppLog.warn("TrashPanel.show aborted, anchor has no window")
            return
        }
        AppLog.info("TrashPanel.show")

        let width: CGFloat = 340
        let height: CGFloat = 420
        let content = TrashPanelView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.onOpenInFinder = { [weak self] url in
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
        content.onEmptiedTrash = { [weak self] in
            if let button = self?.anchor as? TrashButtonView {
                button.refreshIcon()
            }
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = content

        let screenFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
        let x = min(max(screenFrame.maxX - width, screenFrame.minX), (window.screen?.visibleFrame.maxX ?? screenFrame.maxX) - width)
        let y = screenFrame.maxY + 2
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)

        // Accessory (LSUIElement) apps must activate before a panel can take keyboard focus.
        NSApp.activate(ignoringOtherApps: true)
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
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.isDraggingFile else { return }
            self.hide()
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard isVisible else { return event }
        if event.keyCode == 53 { // Escape
            if let content = panel?.contentView as? TrashPanelView, content.hasSearchQuery {
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

/// One directory listing entry — carries `isDirectory` alongside the URL so
/// activation logic doesn't need to re-stat the filesystem on every click.
private struct TrashEntry {
    let url: URL
    let isDirectory: Bool
}

final class TrashPanelView: NSView, NSSearchFieldDelegate {
    var onOpenInFinder: ((URL) -> Void)?
    var onFileOpened: (() -> Void)?
    var onRequestClose: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    /// Fired after Empty Trash completes, so the tray icon can refresh to its empty state.
    var onEmptiedTrash: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Trash")
    private let backButton = NSButton()
    private let searchField = NSSearchField()
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var folderWatcher: DispatchSourceFileSystemObject?
    private var folderFD: Int32 = -1
    private var allFiles: [TrashEntry] = []
    private var filteredFiles: [TrashEntry] = []
    private var needsFullDiskAccess = false
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
        openButton.contentTintColor = NSColor(calibratedRed: 0.35, green: 0.72, blue: 1, alpha: 1)
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

    deinit {
        stopWatching()
    }

    func focusSearch() {
        guard let window else { return }
        window.makeKey()
        window.makeFirstResponder(searchField)
        if let editor = window.fieldEditor(true, for: searchField) as? NSTextView {
            editor.selectAll(nil)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    var hasSearchQuery: Bool {
        !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc private func openFinder() {
        onOpenInFinder?(currentURL)
    }

    @objc private func goBack() {
        guard let previous = backStack.popLast() else { return }
        currentURL = previous
        searchField.stringValue = ""
        updateHeader()
        reloadFromDisk()
        startWatching()
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
        guard alert.runModal() == .alertFirstButtonReturn else {
            AppLog.info("emptyTrash cancelled")
            return
        }

        let root = Self.trashRootURL()
        AppLog.info("emptyTrash confirmed", ["items": allFiles.count])
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
            if let error {
                AppLog.warn("emptyTrash script error", [
                    "errNum": error[NSAppleScript.errorNumber] as? Int ?? 0,
                    "errMsg": error[NSAppleScript.errorMessage] as? String ?? "\(error)"
                ])
            }
            TrashOriginStore.removeAll(under: root)
            DispatchQueue.main.async { [weak self] in
                self?.backStack.removeAll()
                self?.currentURL = root
                self?.updateHeader()
                self?.reloadFromDisk()
                self?.startWatching()
                self?.onEmptiedTrash?()
            }
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
            if !searchField.stringValue.isEmpty {
                searchField.stringValue = ""
                applyFilter()
            } else if !isAtRoot {
                goBack()
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
        activate(first)
    }

    /// Navigate into a folder in-place, or open a file with its default app.
    private func activate(_ entry: TrashEntry) {
        if entry.isDirectory {
            navigate(to: entry.url)
        } else {
            NSWorkspace.shared.open(entry.url)
            onFileOpened?()
        }
    }

    private func navigate(to url: URL) {
        backStack.append(currentURL)
        currentURL = url
        searchField.stringValue = ""
        updateHeader()
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
    private func restore(_ entry: TrashEntry) {
        guard let original = TrashOriginStore.originalURL(for: entry.url) else {
            AppLog.info("restore blocked, unknown origin", ["name": entry.url.lastPathComponent])
            showAlert(
                title: "Can’t Restore “\(entry.url.lastPathComponent)”",
                message: "Better Mac Taskbar doesn’t know where this item was trashed from. Use Finder’s Trash (right-click → Put Back) instead."
            )
            return
        }
        let fm = FileManager.default
        let parent = original.deletingLastPathComponent()
        guard fm.fileExists(atPath: parent.path) else {
            AppLog.warn("restore blocked, origin folder missing", ["parent": parent.path])
            showAlert(
                title: "Can’t Restore “\(entry.url.lastPathComponent)”",
                message: "Its original folder no longer exists."
            )
            return
        }
        var destination = original
        if fm.fileExists(atPath: destination.path) {
            let ext = destination.pathExtension
            let base = destination.deletingPathExtension().lastPathComponent
            destination = ext.isEmpty
                ? parent.appendingPathComponent("\(base) (Restored)")
                : parent.appendingPathComponent("\(base) (Restored)").appendingPathExtension(ext)
        }
        do {
            try fm.moveItem(at: entry.url, to: destination)
            TrashOriginStore.remove(trashedURL: entry.url)
            AppLog.info("restore ok", ["to": destination.path])
            reloadFromDisk()
        } catch {
            AppLog.warn("restore failed", [
                "from": entry.url.path,
                "to": destination.path,
                "error": error.localizedDescription
            ])
            showAlert(title: "Couldn’t Restore “\(entry.url.lastPathComponent)”", message: error.localizedDescription)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func reloadFromDisk() {
        let url = currentURL
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .nameKey]
        do {
            let files = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
            needsFullDiskAccess = false
            let entries = files.map { fileURL in
                let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return TrashEntry(url: fileURL, isDirectory: isDirectory)
            }
            allFiles = entries.sorted { a, b in
                let da = (try? a.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
        } catch {
            // ~/.Trash is TCC-protected — without Full Disk Access this throws
            // NSFileReadNoPermissionError and would otherwise look like "Trash is empty".
            needsFullDiskAccess = (error as NSError).code == 257
            AppLog.warn("trash listing failed", [
                "path": url.path,
                "code": (error as NSError).code,
                "needsFullDiskAccess": needsFullDiskAccess,
                "error": error.localizedDescription
            ])
            allFiles = []
        }
        applyFilter()
    }

    @objc private func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
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
            filteredFiles = allFiles.filter { entry in
                let name = entry.url.lastPathComponent
                return tokens.allSatisfy { name.localizedCaseInsensitiveContains($0) }
            }
        }

        if needsFullDiskAccess {
            addFullDiskAccessMessage()
            return
        }

        if filteredFiles.isEmpty {
            let message = allFiles.isEmpty
                ? (isAtRoot ? "Trash is empty" : "This folder is empty")
                : "No matches"
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
        let allowsRestore = isAtRoot
        for entry in displayed {
            let row = TrashFileRow(entry: entry, width: rowWidth, allowsRestore: allowsRestore)
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
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        }
    }

    private func addFullDiskAccessMessage() {
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
        openSettings.contentTintColor = NSColor(calibratedRed: 0.35, green: 0.72, blue: 1, alpha: 1)
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
        stack.addArrangedSubview(wrap)
    }

    private func startWatching() {
        stopWatching()
        let path = currentURL.path
        folderFD = open(path, O_EVTONLY)
        guard folderFD >= 0 else {
            // Without this fd the list only refreshes on reopen.
            AppLog.warn("trash watcher open failed", ["path": path, "errno": errno])
            return
        }
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
    private var tracking: NSTrackingArea?
    private var mouseDownPoint: NSPoint?
    private var didStartDrag = false

    init(entry: TrashEntry, width: CGFloat, allowsRestore: Bool) {
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
            ImageThumbnailer.thumbnail(for: url, maxPixelSize: 56) { [weak iconView] image in
                guard let image else { return }
                iconView?.image = image
            }
        }

        let nameWidth = width - 56 - (entry.isDirectory ? 18 : 0) - (allowsRestore ? 24 : 0)
        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = NSFont.systemFont(ofSize: 13)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingMiddle
        name.frame = NSRect(x: 44, y: 10, width: max(nameWidth, 60), height: 20)
        addSubview(name)

        if entry.isDirectory {
            let chevron = NSImageView(frame: NSRect(x: width - 48, y: 13, width: 14, height: 14))
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
            restoreButton.frame = NSRect(x: width - 26, y: 9, width: 22, height: 22)
            addSubview(restoreButton)
        }

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
