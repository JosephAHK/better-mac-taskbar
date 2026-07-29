import AppKit
import ImageIO

/// Generates small decoded previews for image files instead of a generic Finder icon.
/// Uses ImageIO's thumbnail API so large photos don't get fully decoded just to show
/// a 28pt row icon.
enum ImageThumbnailer {
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp"
    ]

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Decodes off the main thread; delivers the result on the main queue.
    static func thumbnail(for url: URL, maxPixelSize: CGFloat, completion: @escaping (NSImage?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            DispatchQueue.main.async { completion(image) }
        }
    }
}
