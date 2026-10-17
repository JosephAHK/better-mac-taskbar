import AppKit

/// One directory listing entry for the Downloads and Trash flyouts. Carries what
/// sorting and activation need so neither re-stats the filesystem on the main thread.
struct FolderEntry: Hashable {
    let url: URL
    let isDirectory: Bool
    let modified: Date
}

/// Lists a flyout's folder off the main thread, newest first.
///
/// Every `load` supersedes the one before it: only the newest request's result is
/// delivered, so a slow listing of a folder the user already navigated away from
/// can't overwrite the current one.
@MainActor
final class FolderLoader {
    private static let queue = DispatchQueue(label: "BetterMacTaskbar.folder-listing", qos: .userInitiated)

    private var generation = 0
    private var completion: ((Result<[FolderEntry], Error>) -> Void)?

    func load(_ url: URL, completion: @escaping (Result<[FolderEntry], Error>) -> Void) {
        generation += 1
        let requested = generation
        self.completion = completion
        Self.queue.async {
            let result = Result { try Self.list(url) }
            DispatchQueue.main.async { [weak self] in
                self?.deliver(result, generation: requested)
            }
        }
    }

    private func deliver(_ result: Result<[FolderEntry], Error>, generation delivered: Int) {
        guard delivered == generation else { return }
        completion?(result)
    }

    private nonisolated static func list(_ url: URL) throws -> [FolderEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
        return urls
            .map { fileURL in
                let values = try? fileURL.resourceValues(forKeys: Set(keys))
                return FolderEntry(
                    url: fileURL,
                    isDirectory: values?.isDirectory ?? false,
                    modified: values?.contentModificationDate ?? .distantPast
                )
            }
            .sorted { $0.modified > $1.modified }
    }
}

/// Search, row cap and the non-file rows shared by the Downloads and Trash lists.
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

/// Keeps the row built for each listed entry so a keystroke or watcher tick only
/// builds rows (icon lookup, thumbnail decode) for entries that weren't shown before.
/// An entry whose modification date changed gets a fresh row.
@MainActor
struct FolderRowCache<Row: NSView> {
    private var rows: [FolderEntry: Row] = [:]
    private var message: (text: String, view: NSView)?

    /// The message row for `text`, reused while the text is unchanged so it doesn't
    /// count as a row change either.
    mutating func messageRow(_ text: String, width: CGFloat, height: CGFloat = 80) -> NSView {
        if let message, message.text == text { return message.view }
        let view = FolderList.messageRow(text, width: width, height: height)
        message = (text, view)
        return view
    }

    mutating func rows(for entries: [FolderEntry], make: (FolderEntry) -> Row) -> [Row] {
        var kept: [FolderEntry: Row] = [:]
        let result = entries.map { entry in
            let row = rows[entry] ?? make(entry)
            kept[entry] = row
            return row
        }
        rows = kept
        return result
    }
}
