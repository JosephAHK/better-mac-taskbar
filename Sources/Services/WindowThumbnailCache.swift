import AppKit

/// Last capture per window, shared by the hover preview and the ⌘Tab switcher, so
/// either one opens on an image straight away (refreshed in place) instead of an
/// icon card the image pops into.
@MainActor
final class WindowThumbnailCache {
    static let shared = WindowThumbnailCache()

    /// The switcher asks for every window at once; ScreenCaptureKit slows to a crawl
    /// with dozens of captures in flight, so the rest wait their turn.
    private static let maxConcurrentCaptures = 4

    private struct Request {
        let windowID: CGWindowID
        let size: NSSize
        let scale: CGFloat
    }

    private var images: [CGWindowID: NSImage] = [:]
    private var inFlight: Set<CGWindowID> = []
    private var queue: [Request] = []
    private var listeners: [@MainActor (CGWindowID, NSImage) -> Void] = []

    private init() {}

    func image(for windowID: CGWindowID?) -> NSImage? {
        windowID.flatMap { images[$0] }
    }

    /// Called with every capture that lands, whoever asked for it.
    func addListener(_ listener: @escaping @MainActor (CGWindowID, NSImage) -> Void) {
        listeners.append(listener)
    }

    /// Captures `info` to fit `size` points. A window already being captured (or
    /// waiting to be) is not asked for twice; the capture that lands serves both.
    func capture(_ info: WindowInfo, size: NSSize, scale: CGFloat) {
        guard #available(macOS 14.0, *), WindowThumbnails.isAvailable,
              let windowID = info.cgWindowID,
              !inFlight.contains(windowID),
              !queue.contains(where: { $0.windowID == windowID }) else { return }
        queue.append(Request(windowID: windowID, size: size, scale: scale))
        startQueued()
    }

    /// Drops captures of windows that have gone.
    func prune(keeping liveIDs: Set<CGWindowID>) {
        images = images.filter { liveIDs.contains($0.key) }
    }

    private func startQueued() {
        guard #available(macOS 14.0, *) else { return }
        while inFlight.count < Self.maxConcurrentCaptures, !queue.isEmpty {
            let request = queue.removeFirst()
            inFlight.insert(request.windowID)
            Task {
                let image = await WindowThumbnailer.shared.image(of: request.windowID, fitting: request.size, scale: request.scale)
                self.arrived(image, for: request)
            }
        }
    }

    private func arrived(_ image: CGImage?, for request: Request) {
        inFlight.remove(request.windowID)
        defer { startQueued() }
        guard let image else { return }
        let thumbnail = NSImage(
            cgImage: image,
            size: NSSize(width: CGFloat(image.width) / request.scale, height: CGFloat(image.height) / request.scale)
        )
        // Cached even when it lands after the asker moved on or closed: a capture
        // started during the preview's show delay is meant for the card about to open.
        images[request.windowID] = thumbnail
        for listener in listeners {
            listener(request.windowID, thumbnail)
        }
    }
}
