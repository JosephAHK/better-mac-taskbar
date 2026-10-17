import Foundation

/// Calls back on the main queue when a directory's entries change.
///
/// Events are coalesced: the first one schedules a single callback `coalescing`
/// seconds later and everything arriving before it fires is absorbed. A trailing
/// debounce would be wrong here — an active download writes continuously, so the
/// quiet period a debounce waits for may never come.
///
/// Watching stops when the watcher is released.
@MainActor
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject
    private var pendingFire = false

    /// Returns nil when the directory can't be opened (missing, or blocked by TCC).
    init?(url: URL, coalescing: TimeInterval = 0.25, onChange: @escaping @MainActor @Sendable () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, !self.pendingFire else { return }
            self.pendingFire = true
            DispatchQueue.main.asyncAfter(deadline: .now() + coalescing) { [weak self] in
                guard let self else { return }
                self.pendingFire = false
                onChange()
            }
        }
        // The descriptor is captured by value: the source owns it until cancellation
        // completes, which can be after this watcher (or a replacement) has moved on.
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
