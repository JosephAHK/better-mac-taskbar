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

@MainActor
enum DownloadsPanelController {
    static let shared = FolderFlyoutController { DownloadsPanelView(frame: $0) }
}

/// The Downloads folder, with downloads still in progress on top.
final class DownloadsPanelView: FolderBrowserView {
    private static let sortDefaultsKey = "downloadsSortOrder"
    /// Most Open With lists are short; a long one is mostly apps nobody picks.
    private static let openWithLimit = 10

    private let sortButton: NSButton
    private var progressTimer: Timer?

    /// Newest downloads at the bottom of the list, oldest at the top.
    override var listsNewestLast: Bool { true }

    override var sortOrder: FolderSort {
        UserDefaults.standard.string(forKey: Self.sortDefaultsKey).flatMap(FolderSort.init(rawValue:)) ?? .dateAdded
    }

    init(frame frameRect: NSRect) {
        let sort = NSButton()
        let finder = FolderBrowserView.headerButton(title: "Open in Finder", tint: .controlAccentColor)
        sortButton = sort
        super.init(
            frame: frameRect,
            rootURL: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads"),
            title: "Downloads",
            searchPlaceholder: "Search downloads",
            accessories: [sort, finder]
        )
        finder.target = self
        finder.action = #selector(openCurrentFolderInFinder)

        sort.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "Sort By")
        sort.bezelStyle = .inline
        sort.isBordered = false
        sort.contentTintColor = .secondaryLabelColor
        sort.target = self
        sort.action = #selector(showSortMenu(_:))
        sort.translatesAutoresizingMaskIntoConstraints = false
        updateSortButton()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateSortButton() {
        sortButton.toolTip = "Sort by \(sortOrder.title)"
    }

    @objc private func showSortMenu(_ sender: NSButton) {
        let items = FolderSort.allCases.map { order in
            FolderMenuItem.action(title: order.title, checked: order == sortOrder) { [weak self] in
                guard let self else { return }
                UserDefaults.standard.set(order.rawValue, forKey: Self.sortDefaultsKey)
                self.updateSortButton()
                self.resort()
            }
        }
        presentMenu(items, for: sender, event: nil)
    }

    // MARK: - Hooks

    override func detailText(for entry: FolderEntry) -> String {
        guard entry.isInProgressDownload else { return super.detailText(for: entry) }
        return ["Downloading…", entry.size.map(FolderDetail.size)].compactMap { $0 }.joined(separator: " ")
    }

    override func emptyMessage(atRoot: Bool) -> String {
        atRoot ? "No downloads yet" : "This folder is empty"
    }

    override func hoverAction(for entry: FolderEntry) -> FolderRow.HoverAction? {
        FolderRow.HoverAction(symbolName: "trash", label: "Move to Trash")
    }

    override func performHoverAction(on entry: FolderEntry) {
        moveToTrash(entry)
    }

    override func performDeleteCommand(on entry: FolderEntry) {
        moveToTrash(entry)
    }

    /// A download growing in place doesn't change the folder itself, so the watcher
    /// never fires for it; relist once a second while one is running.
    override func listingDidLoad(_ entries: [FolderEntry]?) {
        progressTimer?.invalidate()
        progressTimer = nil
        guard entries?.contains(where: \.isInProgressDownload) == true else { return }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadListing() }
        }
    }

    override func menuItems(for entry: FolderEntry) -> [FolderMenuItem] {
        var items: [FolderMenuItem] = [
            .action(title: "Open") { [weak self] in self?.open(entry) }
        ]
        if !entry.isFolder {
            let apps = openWithItems(for: entry)
            if !apps.isEmpty {
                items.append(.submenu(title: "Open With", items: apps))
            }
        }
        items += [
            .action(title: "Quick Look") { [weak self] in self?.showQuickLook() },
            .separator,
            .action(title: "Show in Finder") { [weak self] in self?.reveal(entry) },
            .action(title: "Copy") { Self.copyToPasteboard(entry.url) },
            .separator,
            .action(title: "Move to Trash") { [weak self] in self?.moveToTrash(entry) }
        ]
        return items
    }

    // MARK: - Actions

    /// The default app first, then the rest in Launch Services' order.
    private func openWithItems(for entry: FolderEntry) -> [FolderMenuItem] {
        let workspace = NSWorkspace.shared
        let defaultApp = workspace.urlForApplication(toOpen: entry.url)
        var apps = workspace.urlsForApplications(toOpen: entry.url).filter { $0.path != defaultApp?.path }
        if let defaultApp {
            apps.insert(defaultApp, at: 0)
        }
        return apps.prefix(Self.openWithLimit).map { app in
            let name = FileManager.default.displayName(atPath: app.path)
            let icon = workspace.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            return .action(title: app == defaultApp ? "\(name) (default)" : name, image: icon) { [weak self] in
                self?.open(entry, with: app, appName: name)
            }
        }
    }

    private func open(_ entry: FolderEntry, with app: URL, appName: String) {
        let fileName = entry.url.lastPathComponent
        NSWorkspace.shared.open([entry.url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            let message = error.localizedDescription
            DispatchQueue.main.async {
                ErrorAlert.show(title: "Couldn’t Open “\(fileName)” with \(appName)", message: message)
            }
        }
        onOpened?()
    }

    /// As a file URL, which Finder and other apps paste as the file itself.
    private static func copyToPasteboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    private func moveToTrash(_ entry: FolderEntry) {
        var resultingItemURL: NSURL?
        do {
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: &resultingItemURL)
            if let trashedURL = resultingItemURL as URL? {
                TrashOriginStore.record(trashedURL: trashedURL, originalURL: entry.url)
            }
        } catch {
            showError(
                title: "Couldn’t Move “\(entry.url.lastPathComponent)” to the Trash",
                message: error.localizedDescription
            )
        }
        reloadListing()
    }
}
