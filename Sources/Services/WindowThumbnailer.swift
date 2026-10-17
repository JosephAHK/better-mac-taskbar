import AppKit
import ScreenCaptureKit

/// Window images for the hover previews, through ScreenCaptureKit.
///
/// Capturing needs Screen Recording, and a one-shot capture of a single window needs
/// SCScreenshotManager (macOS 14). This never asks for the permission — a capture
/// without it would put up the system prompt the moment the user hovered a button —
/// so callers check `isAvailable`, and only Settings requests the grant.
enum WindowThumbnails {
    /// Whether this macOS can capture single windows at all, granted or not.
    static var isSupported: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    @MainActor
    static var isAvailable: Bool {
        guard #available(macOS 14.0, *) else { return false }
        return CGPreflightScreenCaptureAccess()
    }
}

@available(macOS 14.0, *)
actor WindowThumbnailer {
    static let shared = WindowThumbnailer()

    private var content: SCShareableContent?
    private var contentFetchedAt = Date.distantPast
    /// Listing shareable content walks every window on the system and takes tens of
    /// milliseconds, so one listing serves every capture for a short while. A window
    /// opened since then just waits for the next listing.
    private let contentLifetime: TimeInterval = 2
    /// Windows whose capture has already failed once, so a window that can never be
    /// captured logs once rather than on every refresh.
    private var loggedFailures: Set<CGWindowID> = []
    private var loggedContentFailure = false

    /// The window scaled to fit `size` points at `scale` pixels per point, or nil when
    /// it can't be captured (closed, or a kind ScreenCaptureKit won't hand out).
    func image(of windowID: CGWindowID, fitting size: CGSize, scale: CGFloat) async -> CGImage? {
        guard let window = await window(withID: windowID),
              window.frame.width > 0, window.frame.height > 0 else { return nil }

        let fit = min(size.width / window.frame.width, size.height / window.frame.height, 1)
        let configuration = SCStreamConfiguration()
        // Matching the window's aspect ratio keeps ScreenCaptureKit from letterboxing.
        configuration.width = max(Int(window.frame.width * fit * scale), 1)
        configuration.height = max(Int(window.frame.height * fit * scale), 1)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true

        let filter = SCContentFilter(desktopIndependentWindow: window)
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            loggedFailures.remove(windowID)
            return image
        } catch {
            if loggedFailures.insert(windowID).inserted {
                AppLog.debug("window thumbnail capture failed", [
                    "windowID": Int(windowID),
                    "error": error.localizedDescription
                ])
            }
            return nil
        }
    }

    private func window(withID windowID: CGWindowID) async -> SCWindow? {
        if Date().timeIntervalSince(contentFetchedAt) >= contentLifetime || content == nil {
            do {
                content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                contentFetchedAt = Date()
                loggedContentFailure = false
            } catch {
                if !loggedContentFailure {
                    loggedContentFailure = true
                    AppLog.warn("shareable content unavailable", ["error": error.localizedDescription])
                }
                return nil
            }
        }
        return content?.windows.first { $0.windowID == windowID }
    }
}
