import AppKit
import Quartz

/// Borderless panels refuse key status by default — search needs a key window.
private final class FlyoutKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Presentation for the Downloads and Trash flyouts: a floating panel above the
/// tray button that closes on an outside click, on Escape at the top level, or when
/// the user switches apps, and holds the taskbar visible while it is open.
///
/// The panel and its content are built on first open and kept, hidden, between
/// opens: reopening shows the rows already built instead of listing the folder and
/// building every row again before anything appears.
@MainActor
final class FolderFlyoutController {
    private static let size = NSSize(width: 340, height: 420)

    private let makeContent: (NSRect) -> FolderBrowserView
    private var panel: NSPanel?
    private var content: FolderBrowserView?
    private weak var anchor: NSView?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    /// Drags, menus and alerts run their own event loops; while one is open, a
    /// click outside the panel belongs to it and must not dismiss the flyout.
    private var dismissSuppressions = 0
    private lazy var focus = FlyoutFocus { [weak self] in
        self?.hide(restoringFocus: false)
    }

    var isVisible: Bool { panel?.isVisible == true }

    init(makeContent: @escaping (NSRect) -> FolderBrowserView) {
        self.makeContent = makeContent
    }

    func toggle(relativeTo view: NSView) {
        if isVisible, anchor === view {
            hide()
        } else {
            show(relativeTo: view)
        }
    }

    /// `restoringFocus: false` when whatever caused the hide moves focus itself.
    func hide(restoringFocus: Bool = true) {
        let wasVisible = isVisible
        if wasVisible {
            focus.end(restoringFocus: restoringFocus)
        }
        content?.closeQuickLook()
        removeMonitors()
        panel?.orderOut(nil)
        (anchor as? TrayItemButtonView)?.isOpen = false
        anchor = nil
        dismissSuppressions = 0
        if wasVisible {
            TaskbarPanelController.shared.endKeepVisible()
        }
    }

    private func show(relativeTo view: NSView) {
        for flyout in [DownloadsPanelController.shared, TrashPanelController.shared] where flyout !== self {
            flyout.hide()
        }
        CalendarPanelController.shared.hide()
        hide()
        guard let window = view.window else { return }

        let (panel, content) = panelAndContent()
        content.prepareToShow()

        let width = Self.size.width
        let screenFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
        let x = min(max(screenFrame.maxX - width, screenFrame.minX), (window.screen?.visibleFrame.maxX ?? screenFrame.maxX) - width)
        panel.setFrameOrigin(NSPoint(x: x, y: screenFrame.maxY + 2))

        focus.begin()
        panel.makeKeyAndOrderFront(nil)
        // Defer so the run loop finishes making the panel key first.
        DispatchQueue.main.async {
            content.focusSearch()
        }

        self.anchor = view
        (view as? TrayItemButtonView)?.isOpen = true
        installMonitors()
        TaskbarPanelController.shared.beginKeepVisible()
    }

    private func panelAndContent() -> (NSPanel, FolderBrowserView) {
        if let panel, let content { return (panel, content) }

        let frame = NSRect(origin: .zero, size: Self.size)
        let content = makeContent(frame)
        content.onOpened = { [weak self] in
            self?.hide(restoringFocus: false)
        }
        content.onRequestClose = { [weak self] in
            self?.hide()
        }
        content.onDismissSuppressionChange = { [weak self] active in
            guard let self else { return }
            // Clamped: a hide in the middle of a session already zeroed the count.
            self.dismissSuppressions = max(0, self.dismissSuppressions + (active ? 1 : -1))
        }

        let panel = FlyoutKeyablePanel(
            contentRect: frame,
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
        panel.isReleasedWhenClosed = false
        // Out of full-screen Spaces like the bar it opens from; dark like the bar
        // regardless of the system theme (its text is labelColor on a dark tint).
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = content

        self.panel = panel
        self.content = content
        return (panel, content)
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
            guard let self, self.dismissSuppressions == 0 else { return }
            self.hide(restoringFocus: false)
        }
    }

    /// Keys typed into the flyout — or into Quick Look's panel when the user clicked
    /// it — drive the list. Keys for any other window (an alert, Settings) pass through.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let panel, let content,
              event.window === panel || event.window is QLPreviewPanel else { return event }
        return content.handleKeyDown(event) ? nil : event
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
        guard dismissSuppressions == 0, let panel else { return }
        // Quick Look's panel belongs to the flyout; scrolling a preview isn't leaving it.
        if event.window is QLPreviewPanel { return }
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

/// One entry in a row or header menu. Built by the panels, turned into an NSMenu
/// by `FolderBrowserView.presentMenu`.
enum FolderMenuItem {
    case action(title: String, image: NSImage? = nil, checked: Bool = false, perform: () -> Void)
    case submenu(title: String, items: [FolderMenuItem])
    case separator
}

/// The Downloads and Trash flyouts' shared body: header with back navigation,
/// search, the file list, keyboard selection, Quick Look and row menus. Subclasses
/// supply what differs through the hooks below.
///
/// Keyboard focus stays in the search field the whole time, so typing always
/// searches. The flyout's key monitor routes the list keys here first:
/// - Up/Down select, Return opens (folders open in place), ⌘Return shows in Finder
/// - ⌘Up goes to the parent folder, never above the root
/// - Space toggles Quick Look and ⌘Delete runs the panel's delete command, both
///   only for a selection made with the arrows or a click — after typing, Space is
///   still a space and ⌘Delete still deletes the line
/// - Escape closes Quick Look, then clears the search, then goes up, then closes
class FolderBrowserView: NSView, NSSearchFieldDelegate {
    var onOpened: (() -> Void)?
    var onRequestClose: (() -> Void)?
    var onDismissSuppressionChange: ((Bool) -> Void)?

    let rootURL: URL
    private(set) var currentURL: URL
    var isAtRoot: Bool { backStack.isEmpty }

    private let rootTitle: String
    private let titleLabel = NSTextField(labelWithString: "")
    private let backButton = NSButton()
    private let searchField = NSSearchField()
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let document = NSView()
    private let loader = FolderLoader()
    private var watcher: DirectoryWatcher?
    private var backStack: [URL] = []
    /// Nil until the current folder's first listing arrives, so a folder that is
    /// still loading doesn't flash "empty".
    private var listing: [FolderEntry]?
    private var failureView: NSView?
    /// The entries that have rows, in display order, and their rows.
    private var displayed: [FolderEntry] = []
    private var rows: [FolderRow] = []
    private var rowCache = FolderRowCache()
    private var selectedURL: URL?
    /// The selection came from the arrow keys or a click rather than being the
    /// preselected top search result.
    private var selectionIsExplicit = false
    private var isControllingQuickLook = false
    /// What Quick Look is showing — changes only with the selection, so a watcher
    /// tick that relists the folder doesn't reload the preview.
    private var quickLookURL: URL?

    private var query: String {
        searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var rowWidth: CGFloat { max(bounds.width - 16, 300) }

    init(frame frameRect: NSRect, rootURL: URL, title: String, searchPlaceholder: String, accessories: [NSView]) {
        self.rootURL = rootURL
        self.currentURL = rootURL
        self.rootTitle = title
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

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        backButton.bezelStyle = .inline
        backButton.isBordered = false
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.toolTip = "Back (⌘↑)"
        backButton.isHidden = true
        backButton.translatesAutoresizingMaskIntoConstraints = false

        let headerStack = NSStackView(views: [backButton, titleLabel])
        headerStack.orientation = .horizontal
        headerStack.spacing = 6
        headerStack.alignment = .centerY
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let accessoryStack = NSStackView(views: accessories)
        accessoryStack.orientation = .horizontal
        accessoryStack.spacing = 10
        accessoryStack.alignment = .centerY
        accessoryStack.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = searchPlaceholder
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(headerStack)
        addSubview(accessoryStack)
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
            headerStack.trailingAnchor.constraint(lessThanOrEqualTo: accessoryStack.leadingAnchor, constant: -8),
            backButton.widthAnchor.constraint(equalToConstant: 14),

            accessoryStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            accessoryStack.centerYAnchor.constraint(equalTo: headerStack.centerYAnchor),

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

        reloadFolder()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Subclass hooks

    var sortOrder: FolderSort { .dateAdded }

    /// Date order runs oldest at the top and newest at the bottom.
    var listsNewestLast: Bool { false }

    func detailText(for entry: FolderEntry) -> String {
        FolderDetail.summary(date: entry.added, size: entry.size)
    }

    func emptyMessage(atRoot: Bool) -> String {
        "This folder is empty"
    }

    /// The button revealed on hover.
    func hoverAction(for entry: FolderEntry) -> FolderRow.HoverAction? { nil }

    func performHoverAction(on entry: FolderEntry) {}

    func menuItems(for entry: FolderEntry) -> [FolderMenuItem] { [] }

    /// ⌘Delete on the selected row.
    func performDeleteCommand(on entry: FolderEntry) {}

    /// Shown in place of the list when the folder can't be read; nil shows it as empty.
    func viewForListingFailure(_ error: Error) -> NSView? { nil }

    /// After every listing; `entries` is nil when the folder couldn't be read.
    func listingDidLoad(_ entries: [FolderEntry]?) {}

    // MARK: - Shared actions

    static func headerButton(title: String, tint: NSColor) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = tint
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
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

    /// Each open starts at the root with an empty search and nothing selected. The
    /// rows already built show at once — the watcher kept them current while the
    /// flyout was closed — and a relist re-arms a watcher that couldn't open before
    /// (Trash before Full Disk Access was granted).
    func prepareToShow() {
        rows.forEach { $0.clearHover() }
        guard isAtRoot else {
            returnToRoot()
            return
        }
        searchField.stringValue = ""
        selectedURL = nil
        selectionIsExplicit = false
        applyFilter()
        scrollToFocus()
        reloadFolder()
    }

    @objc func openCurrentFolderInFinder() {
        NSWorkspace.shared.open(currentURL)
        onOpened?()
    }

    /// Navigate into a folder in place, or open a file with its default app.
    func open(_ entry: FolderEntry) {
        if entry.isFolder {
            backStack.append(currentURL)
            show(folder: entry.url, selecting: nil)
        } else {
            NSWorkspace.shared.open(entry.url)
            onOpened?()
        }
    }

    func reveal(_ entry: FolderEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        onOpened?()
    }

    /// Relists the current folder and re-arms its watcher — after the folder changed.
    private func reloadFolder() {
        watcher = DirectoryWatcher(url: currentURL) { [weak self] in self?.reloadListing() }
        reloadListing()
    }

    func reloadListing() {
        loader.load(currentURL) { [weak self] result in
            self?.receive(result)
        }
    }

    /// Reorders the current listing after `sortOrder` changed.
    func resort() {
        guard let listing else { return }
        self.listing = FolderList.sorted(listing, by: sortOrder, newestLast: listsNewestLast)
        applyFilter()
        scrollToFocus()
    }

    func returnToRoot() {
        backStack.removeAll()
        show(folder: rootURL, selecting: nil)
    }

    func withDismissalSuppressed<T>(_ body: () -> T) -> T {
        onDismissSuppressionChange?(true)
        defer { onDismissSuppressionChange?(false) }
        return body()
    }

    func runAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        withDismissalSuppressed { alert.runModal() }
    }

    func showError(title: String, message: String) {
        withDismissalSuppressed { ErrorAlert.show(title: title, message: message) }
    }

    /// Pops `items` up for `view` — at the click for a mouse event, else just below
    /// the view (a header button). The chosen action runs once the menu's
    /// tracking loop has unwound: alerts and Quick Look misbehave inside it.
    func presentMenu(_ items: [FolderMenuItem], for view: NSView, event: NSEvent?) {
        var chosen: (() -> Void)?
        let menu = Self.makeMenu(items) { chosen = $0 }
        withDismissalSuppressed {
            if let event {
                NSMenu.popUpContextMenu(menu, with: event, for: view)
            } else {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.height : 0), in: view)
            }
        }
        chosen?()
    }

    private static func makeMenu(_ items: [FolderMenuItem], choose: @escaping (@escaping () -> Void) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            switch item {
            case .separator:
                menu.addItem(.separator())
            case let .action(title, image, checked, perform):
                let menuItem = ActionMenuItem(title: title, image: image) { choose(perform) }
                menuItem.state = checked ? .on : .off
                menu.addItem(menuItem)
            case let .submenu(title, children):
                let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                parent.submenu = makeMenu(children, choose: choose)
                menu.addItem(parent)
            }
        }
        return menu
    }

    // MARK: - Keyboard

    /// Returns true when the key was handled and must not reach the search field.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 53: // Escape — handled here because the field only sees it while focused.
            handleEscape()
            return true
        case 125 where flags.isEmpty: // Down
            moveSelection(by: 1)
            return true
        case 126 where flags.isEmpty: // Up
            moveSelection(by: -1)
            return true
        case 126 where flags == .command:
            goUp()
            return true
        case 36 where flags.isEmpty || flags == .command, 76 where flags.isEmpty || flags == .command: // Return, keypad Enter
            if let entry = selectedEntry {
                if flags == .command { reveal(entry) } else { open(entry) }
            }
            return true
        case 51 where flags == .command && selectionIsExplicit: // ⌘Delete
            guard let entry = selectedEntry else { return false }
            performDeleteCommand(on: entry)
            return true
        case 49 where flags.isEmpty: // Space
            if isQuickLookVisible {
                closeQuickLook()
                return true
            }
            guard selectionIsExplicit, selectedEntry != nil else { return false }
            showQuickLook()
            return true
        default:
            return false
        }
    }

    func handleEscape() {
        if isQuickLookVisible {
            closeQuickLook()
        } else if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            searchTextChanged()
        } else if !isAtRoot {
            goUp()
        } else {
            onRequestClose?()
        }
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        searchTextChanged()
    }

    func controlTextDidChange(_ obj: Notification) {
        searchTextChanged()
    }

    /// A new query preselects its best result afresh.
    private func searchTextChanged() {
        selectedURL = nil
        selectionIsExplicit = false
        applyFilter()
        scrollToFocus()
    }

    // MARK: - Navigation

    @objc private func goBack() {
        goUp()
    }

    /// The flyout only ever navigates into children, so the parent is always the
    /// previous folder; the folder just left is selected, as in Finder.
    private func goUp() {
        guard let parent = backStack.popLast() else { return }
        show(folder: parent, selecting: currentURL)
    }

    private func show(folder url: URL, selecting selection: URL?) {
        currentURL = url
        searchField.stringValue = ""
        listing = nil
        failureView = nil
        selectedURL = selection
        selectionIsExplicit = selection != nil
        titleLabel.stringValue = isAtRoot ? rootTitle : url.lastPathComponent
        backButton.isHidden = isAtRoot
        applyFilter()
        reloadFolder()
    }

    // MARK: - Listing

    private func receive(_ result: Result<[FolderEntry], Error>) {
        let isFirstListing = listing == nil
        switch result {
        case .success(let entries):
            failureView = nil
            listing = FolderList.sorted(entries, by: sortOrder, newestLast: listsNewestLast)
            listingDidLoad(entries)
        case .failure(let error):
            failureView = viewForListingFailure(error)
            listing = []
            listingDidLoad(nil)
        }
        applyFilter()
        // Only when a folder first appears: later relists (a watcher tick, a growing
        // download) must not yank the list away from where the user scrolled.
        if isFirstListing {
            scrollToFocus()
        }
    }

    /// In date order the newest items are at the bottom of a newest-last list.
    private var newestAtBottom: Bool {
        listsNewestLast && sortOrder == .dateAdded
    }

    /// Brings the selection into view, or else the newest end of the list.
    private func scrollToFocus() {
        let target = selectedIndex.map { rows[$0] } ?? (newestAtBottom ? rows.last : rows.first)
        guard let target else { return }
        scroll.layoutSubtreeIfNeeded()
        target.scrollToVisible(target.bounds)
    }

    private func applyFilter() {
        let previousIndex = selectedIndex
        guard let listing else {
            // Still loading: keep a pending selection (the folder just left) for
            // when the listing lands.
            replaceRows(with: [], views: [])
            refreshSelection()
            return
        }
        if let failureView {
            replaceRows(with: [], views: [failureView])
            reconcileSelection(previousIndex: previousIndex)
            return
        }

        let filtered = FolderList.filter(listing, query: query)
        guard !filtered.isEmpty else {
            let message = listing.isEmpty ? emptyMessage(atRoot: isAtRoot) : "No matches"
            replaceRows(with: [], views: [rowCache.messageRow(message, width: rowWidth)])
            reconcileSelection(previousIndex: previousIndex)
            return
        }

        // The row cap drops the far end from the newest items.
        let shown = Array(newestAtBottom
            ? filtered.suffix(FolderList.displayLimit)
            : filtered.prefix(FolderList.displayLimit))
        let built = rowCache.rows(for: shown, make: makeRow(for:)) { row, entry in
            row.update(entry, detail: detailText(for: entry))
        }
        var views: [NSView] = built
        if filtered.count > shown.count {
            let overflow = FolderList.overflowText(hiddenCount: filtered.count - shown.count)
            let message = rowCache.messageRow(overflow, width: rowWidth, height: 36)
            if newestAtBottom { views.insert(message, at: 0) } else { views.append(message) }
        }
        displayed = shown
        rows = built
        FolderList.setRows(views, in: stack)
        reconcileSelection(previousIndex: previousIndex)
    }

    private func replaceRows(with entries: [FolderEntry], views: [NSView]) {
        displayed = entries
        rows = []
        FolderList.setRows(views, in: stack)
    }

    private func makeRow(for entry: FolderEntry) -> FolderRow {
        let row = FolderRow(entry: entry, width: rowWidth, detail: detailText(for: entry), hoverAction: hoverAction(for: entry))
        row.onSelect = { [weak self, weak row] in
            guard let self, let row else { return }
            self.select(row.entry.url)
        }
        row.onOpen = { [weak self, weak row] revealInFinder in
            guard let self, let row else { return }
            if revealInFinder { self.reveal(row.entry) } else { self.open(row.entry) }
        }
        row.onContextMenu = { [weak self, weak row] event in
            guard let self, let row else { return }
            self.select(row.entry.url)
            let items = self.menuItems(for: row.entry)
            guard !items.isEmpty else { return }
            self.presentMenu(items, for: row, event: event)
        }
        row.onHoverAction = { [weak self, weak row] in
            guard let self, let row else { return }
            self.performHoverAction(on: row.entry)
        }
        row.onDragBegan = { [weak self] in self?.onDismissSuppressionChange?(true) }
        row.onDragEnded = { [weak self] in self?.onDismissSuppressionChange?(false) }
        return row
    }

    // MARK: - Selection

    var selectedEntry: FolderEntry? {
        guard let selectedURL else { return nil }
        return displayed.first { $0.url == selectedURL }
    }

    private var selectedIndex: Int? {
        guard let selectedURL else { return nil }
        return displayed.firstIndex { $0.url == selectedURL }
    }

    /// Explicitly selects `url` (a click, a menu, the arrow keys).
    func select(_ url: URL) {
        selectedURL = url
        selectionIsExplicit = true
        refreshSelection()
        if let index = selectedIndex {
            rows[index].scrollToVisible(rows[index].bounds)
        }
    }

    /// Stops at the ends rather than wrapping, as Finder's lists do.
    private func moveSelection(by delta: Int) {
        guard !displayed.isEmpty else { return }
        let target: Int
        if let index = selectedIndex {
            target = min(max(index + delta, 0), displayed.count - 1)
        } else {
            target = delta > 0 ? 0 : displayed.count - 1
        }
        select(displayed[target].url)
    }

    private func reconcileSelection(previousIndex: Int?) {
        if selectedIndex != nil {
            // Still listed; keep it.
        } else if selectionIsExplicit, let previousIndex, !displayed.isEmpty {
            // The selected item went away (trashed, put back): keep the cursor in
            // place, as Finder does.
            selectedURL = displayed[min(previousIndex, displayed.count - 1)].url
        } else {
            selectionIsExplicit = false
            let best = newestAtBottom ? displayed.last : displayed.first
            selectedURL = query.isEmpty ? nil : best?.url
        }
        refreshSelection()
    }

    private func refreshSelection() {
        for row in rows {
            row.isSelected = row.entry.url == selectedURL
        }
        guard isQuickLookVisible, quickLookURL != selectedEntry?.url else { return }
        if let entry = selectedEntry {
            quickLookURL = entry.url
            QLPreviewPanel.shared().reloadData()
        } else {
            closeQuickLook()
        }
    }

    // MARK: - Quick Look

    /// Quick Look's panel lives in this process, so showing it never makes the app
    /// resign active — FlyoutFocus's app-switch dismissal is unaffected.
    var isQuickLookVisible: Bool {
        isControllingQuickLook && QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    func showQuickLook() {
        guard let entry = selectedEntry, let window, let panel = QLPreviewPanel.shared() else { return }
        quickLookURL = entry.url
        // Above the floating flyout, and ordered front without becoming key, so the
        // search field keeps typing and the arrow keys keep moving the selection.
        if panel.level.rawValue <= window.level.rawValue {
            panel.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        }
        panel.updateController()
        panel.orderFront(nil)
        panel.reloadData()
    }

    func closeQuickLook() {
        guard isQuickLookVisible else { return }
        QLPreviewPanel.shared().orderOut(nil)
        quickLookURL = nil
    }

    // The search field's editor is first responder, so this view is on the key
    // window's responder chain, where Quick Look looks for its controller. Quick
    // Look's callbacks are unannotated but always arrive on the main thread.
    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            isControllingQuickLook = true
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            isControllingQuickLook = false
            quickLookURL = nil
        }
    }

    private var quickLookRow: FolderRow? {
        rows.first { $0.entry.url == quickLookURL }
    }
}

extension FolderBrowserView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { quickLookURL == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { quickLookURL as NSURL? }
    }

    /// Zooms from the row's icon when it's on screen.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        MainActor.assumeIsolated {
            guard let row = quickLookRow, let window = row.window, !row.visibleRect.isEmpty else { return .zero }
            return window.convertToScreen(row.convert(row.iconFrame, to: nil))
        }
    }
}

/// A file or folder row: icon (a thumbnail for images), name, details, a hover
/// action, drag-out, selection and a context menu.
final class FolderRow: NSView, NSDraggingSource {
    struct HoverAction {
        let symbolName: String
        let label: String
    }

    private(set) var entry: FolderEntry
    var onSelect: (() -> Void)?
    var onOpen: ((_ revealInFinder: Bool) -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    var onHoverAction: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            refreshBackground()
        }
    }

    var iconFrame: NSRect { iconView.frame }

    private static let height: CGFloat = 44
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()
    private let hoverAction: HoverAction?
    private var thumbnailRequest: Operation?
    private var hasThumbnail = false
    private var tracking: NSTrackingArea?
    private var isHovered = false
    private var mouseDownPoint: NSPoint?
    private var didStartDrag = false

    init(entry: FolderEntry, width: CGFloat, detail: String, hoverAction: HoverAction?) {
        self.entry = entry
        self.hoverAction = hoverAction
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        wantsLayer = true
        layer?.cornerRadius = 4

        iconView.frame = NSRect(x: 8, y: 8, width: 28, height: 28)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = NSWorkspace.shared.icon(forFile: entry.url.path)
        addSubview(iconView)

        // Everything right-aligned is inset by the scroller gutter — see PanelMetrics.
        let gutter = PanelMetrics.scrollerGutter
        let hasStatusSlot = entry.isFolder || entry.isInProgressDownload
        let textWidth = max(width - 56 - gutter - (hasStatusSlot ? 18 : 0) - (hoverAction != nil ? 24 : 0), 60)

        nameLabel.stringValue = entry.url.lastPathComponent
        nameLabel.font = NSFont.systemFont(ofSize: 13)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.frame = NSRect(x: 44, y: 21, width: textWidth, height: 17)
        addSubview(nameLabel)

        detailLabel.stringValue = detail
        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.frame = NSRect(x: 44, y: 6, width: textWidth, height: 14)
        addSubview(detailLabel)

        if entry.isInProgressDownload {
            // How far along isn't knowable from the placeholder alone; the detail
            // text's growing size carries the progress.
            let spinner = NSProgressIndicator(frame: NSRect(x: width - 49 - gutter, y: 14, width: 16, height: 16))
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.isDisplayedWhenStopped = false
            spinner.startAnimation(nil)
            addSubview(spinner)
        } else if entry.isFolder {
            let chevron = NSImageView(frame: NSRect(x: width - 48 - gutter, y: 15, width: 14, height: 14))
            chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
            chevron.contentTintColor = .tertiaryLabelColor
            chevron.imageScaling = .scaleProportionallyUpOrDown
            addSubview(chevron)
        }

        if let hoverAction {
            actionButton.image = NSImage(systemSymbolName: hoverAction.symbolName, accessibilityDescription: hoverAction.label)
            actionButton.bezelStyle = .inline
            actionButton.isBordered = false
            actionButton.contentTintColor = .secondaryLabelColor
            actionButton.toolTip = hoverAction.label
            actionButton.target = self
            actionButton.action = #selector(actionTapped)
            actionButton.isHidden = true
            actionButton.frame = NSRect(x: width - 26 - gutter, y: 11, width: 22, height: 22)
            addSubview(actionButton)
        }

        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        widthAnchor.constraint(equalToConstant: width).isActive = true
        TaskbarAppearance.addObserver(self, selector: #selector(refreshBackground))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The same item, changed on disk (a growing download, an edited image).
    func update(_ entry: FolderEntry, detail: String) {
        let modifiedChanged = entry.modified != self.entry.modified
        self.entry = entry
        detailLabel.stringValue = detail
        if modifiedChanged {
            thumbnailRequest?.cancel()
            thumbnailRequest = nil
            hasThumbnail = false
            requestThumbnailIfNeeded()
        }
    }

    /// Thumbnails are decoded only while the row is on screen: leaving the window
    /// (filtered out, a folder left) cancels a pending decode, and coming back
    /// requests it again — from the cache when it had finished.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            thumbnailRequest?.cancel()
            thumbnailRequest = nil
        } else {
            requestThumbnailIfNeeded()
        }
    }

    private func requestThumbnailIfNeeded() {
        guard window != nil, !hasThumbnail, thumbnailRequest == nil,
              !entry.isFolder, ImageThumbnailer.isImage(entry.url) else { return }
        thumbnailRequest = ImageThumbnailer.thumbnail(for: entry.url, modified: entry.modified, maxPixelSize: 56) { [weak self] image in
            guard let self else { return }
            self.iconView.image = image
            self.hasThumbnail = true
            self.thumbnailRequest = nil
        }
    }

    @objc private func refreshBackground() {
        let color: NSColor
        if isSelected {
            color = NSColor.controlAccentColor.withAlphaComponent(0.55)
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
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        actionButton.isHidden = hoverAction == nil
        refreshBackground()
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    /// Also when the flyout reopens: a panel ordered out under the pointer never
    /// gets the mouse-exited event.
    func clearHover() {
        guard isHovered else { return }
        isHovered = false
        actionButton.isHidden = true
        refreshBackground()
    }

    @objc private func actionTapped() {
        onHoverAction?()
    }

    override func mouseDown(with event: NSEvent) {
        // ⌃-click is a right-click on a Mac trackpad or one-button mouse.
        if event.modifierFlags.contains(.control) {
            onContextMenu?(event)
            return
        }
        onSelect?()
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        didStartDrag = false
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !didStartDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard abs(point.x - start.x) >= 4 || abs(point.y - start.y) >= 4 else { return }

        didStartDrag = true
        onDragBegan?()

        let item = NSDraggingItem(pasteboardWriter: entry.url as NSURL)
        item.setDraggingFrame(
            NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32),
            contents: iconView.image
        )
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            didStartDrag = false
        }
        guard !didStartDrag, mouseDownPoint != nil else { return }
        // Finder-style: a single click selects, a double-click opens.
        guard event.clickCount >= 2 else { return }
        onOpen?(event.modifierFlags.contains(.command))
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
