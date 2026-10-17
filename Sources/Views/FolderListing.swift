import AppKit

/// One directory listing entry for the Downloads and Trash flyouts. Carries what
/// sorting, row details and activation need so none of them re-stat the filesystem
/// on the main thread.
struct FolderEntry: Equatable {
    let url: URL
    /// A directory the flyout navigates into. Packages (apps, Safari's `.download`
    /// bundles) are directories on disk but open like files, as in Finder.
    let isFolder: Bool
    let modified: Date
    /// When the item arrived in its folder: download time in Downloads, the time it
    /// was trashed in the Trash. Falls back to the creation date where the volume
    /// doesn't record it.
    let added: Date
    /// Logical size. Nil for folders and finished packages, which would need a
    /// recursive scan — Finder's list view leaves them blank too.
    let size: Int64?
    /// Localized kind ("PDF document", "Folder"), for sorting by kind.
    let kind: String

    /// Browsers download into a placeholder and rename it when the download completes.
    private static let inProgressExtensions: Set<String> = ["crdownload", "download", "part", "opdownload"]

    var isInProgressDownload: Bool { Self.isInProgressDownload(url) }

    static func isInProgressDownload(_ url: URL) -> Bool {
        inProgressExtensions.contains(url.pathExtension.lowercased())
    }
}

/// Lists a flyout's folder off the main thread.
///
/// Every `load` supersedes the one before it: only the newest request's result is
/// delivered, so a slow listing of a folder the user already navigated away from
/// can't overwrite the current one.
@MainActor
final class FolderLoader {
    private static let queue = DispatchQueue(label: "BetterMacTaskbar.folder-listing", qos: .userInitiated)

    private nonisolated static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .contentModificationDateKey, .addedToDirectoryDateKey,
        .creationDateKey, .fileSizeKey, .localizedTypeDescriptionKey
    ]

    private var generation = 0

    func load(_ url: URL, completion: @escaping @MainActor (Result<[FolderEntry], Error>) -> Void) {
        generation += 1
        let requested = generation
        Self.queue.async {
            let result = Result { try Self.list(url) }
            DispatchQueue.main.async { [weak self] in
                guard let self, requested == self.generation else { return }
                completion(result)
            }
        }
    }

    private nonisolated static func list(_ url: URL) throws -> [FolderEntry] {
        try FileManager.default
            .contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            .map(entry(for:))
    }

    private nonisolated static func entry(for url: URL) -> FolderEntry {
        let values = try? url.resourceValues(forKeys: Set(keys))
        let isDirectory = values?.isDirectory ?? false
        let modified = values?.contentModificationDate ?? .distantPast
        // Safari's .download is a bundle holding the partial file. It must open like
        // a file even if Safari's package type isn't registered, and its growing size
        // is the point of showing it — it only holds a few files, so sizing is cheap.
        let isDownloadBundle = isDirectory && FolderEntry.isInProgressDownload(url)
        let size: Int64?
        if isDownloadBundle {
            size = bundleSize(url)
        } else {
            size = isDirectory ? nil : values?.fileSize.map(Int64.init)
        }
        return FolderEntry(
            url: url,
            isFolder: isDirectory && !(values?.isPackage ?? false) && !isDownloadBundle,
            modified: modified,
            added: values?.addedToDirectoryDate ?? values?.creationDate ?? modified,
            size: size,
            kind: values?.localizedTypeDescription ?? ""
        )
    }

    private nonisolated static func bundleSize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

/// Orders for the Downloads list. Raw values are persisted.
enum FolderSort: String, CaseIterable {
    case dateAdded
    case name
    case size
    case kind

    var title: String {
        switch self {
        case .dateAdded: return "Date Added"
        case .name: return "Name"
        case .size: return "Size"
        case .kind: return "Kind"
        }
    }
}

/// Search, sorting, row cap and the non-file rows shared by the Downloads and Trash lists.
@MainActor
enum FolderList {
    /// Rows past this are never built — a few thousand downloads would otherwise
    /// stall every keystroke. The overflow row tells the user to narrow the search.
    static let displayLimit = 150

    /// Every whitespace-separated token must appear in the name, in any order.
    static func filter(_ entries: [FolderEntry], query: String) -> [FolderEntry] {
        let tokens = query.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return entries }
        return entries.filter { entry in
            let name = entry.url.lastPathComponent
            return tokens.allSatisfy { name.localizedStandardContains($0) }
        }
    }

    /// Dates run newest first, or newest last with `newestLast`; sizes run largest
    /// first, as in Finder; ties fall back to name. Downloads still in progress sit
    /// at the newest end — they're what the user is waiting on — and at the top in
    /// the other orders.
    static func sorted(_ entries: [FolderEntry], by order: FolderSort, newestLast: Bool = false) -> [FolderEntry] {
        let inProgressLast = newestLast && order == .dateAdded
        return entries.sorted { a, b in
            if a.isInProgressDownload != b.isInProgressDownload {
                return inProgressLast ? b.isInProgressDownload : a.isInProgressDownload
            }
            switch order {
            case .dateAdded:
                if a.added != b.added { return newestLast ? a.added < b.added : a.added > b.added }
            case .name:
                break
            case .size:
                // Unsized items (folders, apps) sink to the bottom.
                if a.size != b.size { return (a.size ?? -1) > (b.size ?? -1) }
            case .kind:
                let byKind = a.kind.localizedStandardCompare(b.kind)
                if byKind != .orderedSame { return byKind == .orderedAscending }
            }
            return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
    }

    /// Centered secondary text — empty folder, no matches, or the overflow count.
    static func messageRow(_ text: String, width: CGFloat, height: CGFloat = 80) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(label)
        NSLayoutConstraint.activate([
            wrap.heightAnchor.constraint(equalToConstant: height),
            label.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            wrap.widthAnchor.constraint(equalToConstant: width)
        ])
        return wrap
    }

    static func overflowText(hiddenCount: Int) -> String {
        "\(hiddenCount) more — refine search"
    }

    /// Replaces the stack's rows only when they actually differ, so a watcher tick
    /// that changed nothing visible doesn't tear down hover state or relayout.
    static func setRows(_ rows: [NSView], in stack: NSStackView) {
        guard stack.arrangedSubviews != rows else { return }
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            if !rows.contains(view) { view.removeFromSuperview() }
        }
        rows.forEach(stack.addArrangedSubview)
    }
}

/// Secondary row text: "Today 10:42", "Yesterday", "Mar 3", sizes as Finder shows them.
@MainActor
enum FolderDetail {
    /// Relative formatting supplies the localized "Today" / "Yesterday".
    private static let relativeDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func date(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "\(relativeDay.string(from: date)) \(date.formatted(date: .omitted, time: .shortened))"
        }
        if calendar.isDateInYesterday(date) {
            return relativeDay.string(from: date)
        }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.year().month(.abbreviated).day())
    }

    static func size(_ byteCount: Int64) -> String {
        bytes.string(fromByteCount: byteCount)
    }

    /// "Mar 3 · 2.1 MB", or just the date for unsized items.
    static func summary(date: Date, size: Int64?) -> String {
        [Self.date(date), size.map(Self.size)].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Keeps the row built for each listed item so a keystroke or watcher tick only
/// builds rows (icon lookup, thumbnail decode) for items that weren't shown before.
/// Rows are keyed by URL and updated in place when the item changes, so a growing
/// download keeps its row — hover state and progress animation included.
@MainActor
struct FolderRowCache {
    private var rows: [URL: FolderRow] = [:]
    private var message: (text: String, view: NSView)?

    /// The message row for `text`, reused while the text is unchanged so it doesn't
    /// count as a row change either.
    mutating func messageRow(_ text: String, width: CGFloat, height: CGFloat = 80) -> NSView {
        if let message, message.text == text { return message.view }
        let view = FolderList.messageRow(text, width: width, height: height)
        message = (text, view)
        return view
    }

    mutating func rows(
        for entries: [FolderEntry],
        make: (FolderEntry) -> FolderRow,
        update: (FolderRow, FolderEntry) -> Void
    ) -> [FolderRow] {
        var kept: [URL: FolderRow] = [:]
        let result = entries.map { entry -> FolderRow in
            let row: FolderRow
            // A file replaced by a folder of the same name needs a different row.
            if let cached = rows[entry.url], cached.entry.isFolder == entry.isFolder {
                if cached.entry != entry { update(cached, entry) }
                row = cached
            } else {
                row = make(entry)
            }
            kept[entry.url] = row
            return row
        }
        rows = kept
        return result
    }
}
