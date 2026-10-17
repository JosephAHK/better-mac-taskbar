import AppKit

/// Taskbar Trash button — browse, restore, or empty the Trash without opening Finder.
final class TrashButtonView: TrayItemButtonView {
    /// Keeps the can's full/empty state live when Finder (or anything else) changes
    /// the Trash. Nil if ~/.Trash can't be opened; the icon then still refreshes on hover.
    private var trashWatcher: DirectoryWatcher?

    init() {
        super.init(title: "Trash")
        refreshIcon()
        trashWatcher = DirectoryWatcher(url: TrashPanelView.trashURL) { [weak self] in
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
        iconView.image = NSImage(named: Self.isTrashEmpty() ? NSImage.trashEmptyName : NSImage.trashFullName)
    }

    /// Stops at the first visible item — this runs on every Trash change and hover,
    /// and listing a large Trash in full each time would stall the main thread.
    private static func isTrashEmpty() -> Bool {
        let enumerator = FileManager.default.enumerator(
            at: TrashPanelView.trashURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            // Unreadable Trash reads as empty: showing a full can for a folder we cannot
            // enumerate would be a permanent false positive.
            errorHandler: { _, _ in false }
        )
        return enumerator?.nextObject() == nil
    }
}

@MainActor
enum TrashPanelController {
    static let shared = FolderFlyoutController { TrashPanelView(frame: $0) }
}

/// ~/.Trash, with Put Back and Delete Immediately on its items.
final class TrashPanelView: FolderBrowserView {
    static let trashURL: URL =
        (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")

    private var isEmptying = false
    private lazy var fullDiskAccessMessage: NSView = makeFullDiskAccessMessage()

    init(frame frameRect: NSRect) {
        let empty = FolderBrowserView.headerButton(title: "Empty", tint: .systemRed)
        let finder = FolderBrowserView.headerButton(title: "Finder", tint: .controlAccentColor)
        super.init(
            frame: frameRect,
            rootURL: Self.trashURL,
            title: "Trash",
            searchPlaceholder: "Search trash",
            accessories: [empty, finder]
        )
        empty.target = self
        empty.action = #selector(emptyTapped)
        finder.target = self
        finder.action = #selector(openCurrentFolderInFinder)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Hooks

    override func emptyMessage(atRoot: Bool) -> String {
        atRoot ? "Trash is empty" : "This folder is empty"
    }

    /// Put Back moves a top-level item out of its Trash; inside a trashed folder
    /// there's no origin to return to.
    override func hoverAction(for entry: FolderEntry) -> FolderRow.HoverAction? {
        isAtRoot ? FolderRow.HoverAction(symbolName: "arrow.up.bin", label: "Put Back") : nil
    }

    override func performHoverAction(on entry: FolderEntry) {
        putBack(entry)
    }

    override func performDeleteCommand(on entry: FolderEntry) {
        deleteImmediately(entry)
    }

    override func menuItems(for entry: FolderEntry) -> [FolderMenuItem] {
        var items: [FolderMenuItem] = []
        if isAtRoot {
            items.append(.action(title: "Put Back") { [weak self] in self?.putBack(entry) })
        }
        items += [
            .action(title: "Show in Finder") { [weak self] in self?.reveal(entry) },
            .separator,
            .action(title: "Delete Immediately…") { [weak self] in self?.deleteImmediately(entry) }
        ]
        return items
    }

    /// ~/.Trash is TCC-protected — without Full Disk Access listing it throws
    /// NSFileReadNoPermissionError, which would otherwise look like an empty Trash.
    override func viewForListingFailure(_ error: Error) -> NSView? {
        (error as NSError).code == NSFileReadNoPermissionError ? fullDiskAccessMessage : nil
    }

    // MARK: - Empty

    @objc private func emptyTapped() {
        let alert = NSAlert()
        alert.messageText = "Empty Trash?"
        alert.informativeText = "This will permanently erase the items in the Trash. This can’t be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard !isEmptying, runAlert(alert) == .alertFirstButtonReturn else { return }

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
            showError(title: "Couldn’t Empty the Trash", message: error.localizedDescription)
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
            withDismissalSuppressed {
                ErrorAlert.showAppleScriptFailure(
                    title: "Couldn’t Empty the Trash",
                    targetApp: "Finder",
                    code: code,
                    message: message.isEmpty ? "Finder didn’t empty the Trash." : message
                )
            }
            return
        }
        TrashOriginStore.removeAll(under: rootURL)
        returnToRoot()
    }

    // MARK: - Put Back

    /// Put Back only works reliably for items this app itself trashed (tracked
    /// origin) — items Finder trashed (or trashed before this store existed) have no
    /// known origin, so we tell the user rather than guessing a destination.
    private func putBack(_ entry: FolderEntry) {
        let name = entry.url.lastPathComponent
        let original: URL
        switch TrashOriginStore.origin(for: entry.url) {
        case .verified(let url):
            original = url
        case .unverified(let url):
            guard confirmUnverifiedPutBack(name: name, to: url.deletingLastPathComponent()) else { return }
            original = url
        case nil:
            showError(
                title: "Can’t Put Back “\(name)”",
                message: "Better Mac Taskbar doesn’t know where this item was trashed from. Use Finder’s Trash (right-click → Put Back) instead."
            )
            return
        }

        let fm = FileManager.default
        let parent = original.deletingLastPathComponent()
        guard fm.fileExists(atPath: parent.path) else {
            showError(title: "Can’t Put Back “\(name)”", message: "Its original folder no longer exists.")
            return
        }
        let destination = Self.availableRestoreURL(for: original)
        do {
            try fm.moveItem(at: entry.url, to: destination)
            TrashOriginStore.remove(trashedURL: entry.url)
            reloadListing()
        } catch {
            showError(title: "Couldn’t Put Back “\(name)”", message: error.localizedDescription)
        }
    }

    /// Origins recorded by older versions carry no file identity, so the record may
    /// belong to an earlier item with the same name that has since been emptied.
    private func confirmUnverifiedPutBack(name: String, to folder: URL) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Put back “\(name)” to “\(folder.lastPathComponent)”?"
        alert.informativeText = "An item with this name was trashed from \(folder.path), but Better Mac Taskbar can’t confirm it’s this one."
        alert.addButton(withTitle: "Put Back")
        alert.addButton(withTitle: "Cancel")
        return runAlert(alert) == .alertFirstButtonReturn
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

    // MARK: - Delete Immediately

    /// Finder's wording. Removal runs off the main thread: a large folder can take
    /// a while, and the flyout shouldn't freeze meanwhile.
    private func deleteImmediately(_ entry: FolderEntry) {
        let name = entry.url.lastPathComponent
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Are you sure you want to delete “\(name)”?"
        alert.informativeText = "This item will be deleted immediately. You can’t undo this action."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard runAlert(alert) == .alertFirstButtonReturn else { return }

        let url = entry.url
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async { [weak self, failure] in
                if failure == nil {
                    TrashOriginStore.remove(trashedURL: url)
                }
                // Relist either way: a failed folder removal may still have removed part of it.
                self?.reloadListing()
                guard let failure else { return }
                let title = "Couldn’t Delete “\(name)”"
                if let self {
                    self.showError(title: title, message: failure)
                } else {
                    ErrorAlert.show(title: title, message: failure)
                }
            }
        }
    }

    // MARK: - Full Disk Access

    @objc private func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

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
}
