import Foundation

/// Records where an item was trashed from, so the Trash panel can offer a reliable
/// "restore" action for anything this app itself sent to Trash. Items trashed by
/// Finder (or before this store existed) have no recorded origin — restore falls
/// back to telling the user rather than guessing a destination.
@MainActor
enum TrashOriginStore {
    enum Origin {
        /// The item at the trashed path is the one this app trashed.
        case verified(URL)
        /// Recorded before identities were stored, so it may describe an earlier
        /// item that happened to have the same name.
        case unverified(URL)
    }

    /// The exact file system object that was trashed. A path alone isn't enough:
    /// after Finder empties the Trash, a later, unrelated item with the same name
    /// lands at the same path. Moving to the Trash is a rename, which keeps all three.
    private struct Identity: Codable, Equatable {
        let device: Int32
        let inode: UInt64
        let created: Double

        init?(url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
            created = Double(info.st_birthtimespec.tv_sec) + Double(info.st_birthtimespec.tv_nsec) / 1_000_000_000
        }
    }

    private struct Record: Codable {
        let originalPath: String
        /// Nil for records written before identities were stored.
        let identity: Identity?

        init(originalPath: String, identity: Identity?) {
            self.originalPath = originalPath
            self.identity = identity
        }

        /// Earlier versions stored the original path as a bare string.
        init(from decoder: Decoder) throws {
            if let legacyPath = try? decoder.singleValueContainer().decode(String.self) {
                self.init(originalPath: legacyPath, identity: nil)
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                originalPath: try container.decode(String.self, forKey: .originalPath),
                identity: try container.decodeIfPresent(Identity.self, forKey: .identity)
            )
        }
    }

    private static let storeURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Better Mac Taskbar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("trash-origins.json")
    }()

    private static var cache: [String: Record]?

    private static func load() -> [String: Record] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: storeURL),
              let map = try? JSONDecoder().decode([String: Record].self, from: data) else {
            cache = [:]
            return [:]
        }
        // Drop records for items that have since left the Trash by any route (emptied
        // in Finder, put back, deleted). Only a definite "no such file" counts: without
        // Full Disk Access a stat inside ~/.Trash can fail with EPERM instead.
        let live = map.filter { path, _ in
            var info = stat()
            return lstat(path, &info) == 0 || errno != ENOENT
        }
        if live.count != map.count {
            save(live)
        } else {
            cache = live
        }
        return live
    }

    private static func save(_ map: [String: Record]) {
        cache = map
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    static func record(trashedURL: URL, originalURL: URL) {
        var map = load()
        map[trashedURL.path] = Record(originalPath: originalURL.path, identity: Identity(url: trashedURL))
        save(map)
    }

    /// Nil when no origin is known, including when the item now at `trashedURL` isn't
    /// the one that was recorded there.
    static func origin(for trashedURL: URL) -> Origin? {
        guard let record = load()[trashedURL.path] else { return nil }
        let original = URL(fileURLWithPath: record.originalPath)
        guard let recorded = record.identity else { return .unverified(original) }
        guard let current = Identity(url: trashedURL) else { return nil }
        guard current == recorded else {
            remove(trashedURL: trashedURL)
            return nil
        }
        return .verified(original)
    }

    static func remove(trashedURL: URL) {
        var map = load()
        map.removeValue(forKey: trashedURL.path)
        save(map)
    }

    /// Drop every record whose trashed path lives under `root` — called after Empty
    /// Trash. The separator keeps a sibling folder whose name merely starts the same
    /// way out of it.
    static func removeAll(under root: URL) {
        var map = load()
        let prefix = root.path + "/"
        map = map.filter { !$0.key.hasPrefix(prefix) }
        save(map)
    }
}
