import Foundation

/// Records where an item was trashed from, so the Trash panel can offer a reliable
/// "restore" action for anything this app itself sent to Trash. Items trashed by
/// Finder (or before this store existed) have no recorded origin — restore falls
/// back to telling the user rather than guessing a destination.
enum TrashOriginStore {
    private static let storeURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Better Mac Taskbar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("trash-origins.json")
    }()

    private static var cache: [String: String]?

    private static func load() -> [String: String] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: storeURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            cache = [:]
            return [:]
        }
        cache = map
        return map
    }

    private static func save(_ map: [String: String]) {
        cache = map
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    static func record(trashedURL: URL, originalURL: URL) {
        var map = load()
        map[trashedURL.path] = originalURL.path
        save(map)
    }

    static func originalURL(for trashedURL: URL) -> URL? {
        guard let path = load()[trashedURL.path] else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func remove(trashedURL: URL) {
        var map = load()
        map.removeValue(forKey: trashedURL.path)
        save(map)
    }

    /// Drop every record whose trashed path lives under `root` — called after Empty Trash.
    static func removeAll(under root: URL) {
        var map = load()
        let prefix = root.path
        map = map.filter { !$0.key.hasPrefix(prefix) }
        save(map)
    }
}
