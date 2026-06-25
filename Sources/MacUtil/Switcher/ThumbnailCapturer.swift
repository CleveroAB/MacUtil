import AppKit
import ScreenCaptureKit

/// Captures one-shot window thumbnails on demand via ScreenCaptureKit.
///
/// Still **no `SCStream` / no background timer** — captures happen only when the
/// switcher opens, so idle cost stays at zero. To make opening fast we cache the
/// *shareable-window list* (the `SCShareableContent` enumeration is the slow part)
/// and reuse it, refreshing in the background after each open and at launch. The
/// thumbnail images themselves are always captured fresh, so previews never go
/// stale; only the cheap window list is cached.
enum ThumbnailCapturer {

    /// Capture target width in px. Smaller = faster capture; 256 is still crisp at
    /// the ~160 pt card size on Retina.
    private static let maxWidth: CGFloat = 256

    /// Cached shareable windows by id. Accessed on the main thread only.
    private static var cache: [CGWindowID: SCWindow] = [:]

    // MARK: Cache

    /// Cached `SCWindow`s for the given ids (main-thread). Empty entries are dropped.
    static func cachedTargets(for ids: [CGWindowID]) -> [SCWindow] {
        ids.compactMap { cache[$0] }
    }

    /// Refresh the cached window list in the background. Also primes Screen
    /// Recording (the first call registers the app + shows the one-time prompt).
    static func refresh() {
        Task {
            guard let content = await shareableContent() else { return }
            await MainActor.run {
                cache = Dictionary(
                    content.windows.map { ($0.windowID, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                DebugLog.log("[MacUtil] sc-cache: \(content.windows.count) windows")
            }
        }
    }

    // MARK: Capture

    /// Fast path: capture already-resolved (cached) windows — no enumeration.
    static func capture(_ scWindows: [SCWindow]) async -> [CGWindowID: NSImage] {
        await captureWindows(scWindows)
    }

    /// Fallback: enumerate live (cache miss / new window), capture, refresh cache.
    static func captureLive(ids: [CGWindowID]) async -> [CGWindowID: NSImage] {
        guard let content = await shareableContent() else { return [:] }
        await MainActor.run {
            cache = Dictionary(
                content.windows.map { ($0.windowID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        let wanted = Set(ids)
        return await captureWindows(content.windows.filter { wanted.contains($0.windowID) })
    }

    // MARK: Private

    private static func shareableContent() async -> SCShareableContent? {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            DebugLog.log("[MacUtil] screen-recording: NOT granted / SCShareableContent failed — \(error.localizedDescription)")
            return nil
        }
    }

    private static func captureWindows(_ targets: [SCWindow]) async -> [CGWindowID: NSImage] {
        guard !targets.isEmpty else { return [:] }
        var images: [CGWindowID: NSImage] = [:]
        await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
            for window in targets {
                group.addTask { (window.windowID, await captureOne(window)) }
            }
            for await (id, image) in group {
                if let image { images[id] = image }
            }
        }
        DebugLog.log("[MacUtil] thumbnails: captured \(images.count)/\(targets.count)")
        return images
    }

    private static func captureOne(_ window: SCWindow) async -> NSImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let width = max(window.frame.width, 1)
        let scale = width > maxWidth ? maxWidth / width : 1
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false

        do {
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            return nil
        }
    }
}
