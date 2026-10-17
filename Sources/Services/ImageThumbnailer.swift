import AppKit
import ImageIO

/// Generates small decoded previews for image files instead of a generic Finder icon.
/// Uses ImageIO's thumbnail API so large photos don't get fully decoded just to show
/// a 28pt row icon.
@MainActor
enum ImageThumbnailer {
    private nonisolated static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp"
    ]

    /// Keyed by path, modification date and size, so an edited image gets a fresh
    /// preview while rebuilt rows (every search keystroke) reuse the old one.
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        return cache
    }()

    /// A folder of photos would otherwise queue one decode per row on the global pool
    /// at once; a few at a time keeps the CPU free for scrolling.
    private static let decodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "BetterMacTaskbar.thumbnails"
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .utility
        return queue
    }()

    nonisolated static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Delivers a cached thumbnail immediately, otherwise decodes off the main thread
    /// and delivers on the main queue. Returns the decode, which the caller cancels
    /// when its row goes away; a cancelled decode never calls `completion`.
    @discardableResult
    static func thumbnail(
        for url: URL,
        modified: Date,
        maxPixelSize: CGFloat,
        completion: @escaping @MainActor @Sendable (NSImage) -> Void
    ) -> Operation? {
        let key = "\(url.path)|\(modified.timeIntervalSinceReferenceDate)|\(maxPixelSize)"
        if let cached = cache.object(forKey: key as NSString) {
            completion(cached)
            return nil
        }

        let operation = BlockOperation()
        operation.addExecutionBlock { [unowned operation] in
            guard !operation.isCancelled,
                  let cgImage = decode(url, maxPixelSize: maxPixelSize) else { return }
            DispatchQueue.main.async {
                guard !operation.isCancelled else { return }
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                cache.setObject(image, forKey: key as NSString)
                completion(image)
            }
        }
        decodeQueue.addOperation(operation)
        return operation
    }

    private nonisolated static func decode(_ url: URL, maxPixelSize: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
