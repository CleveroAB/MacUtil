import AppKit
import ApplicationServices

/// Reads and writes the frontmost window's geometry through the Accessibility API.
///
/// All public frame methods speak **Cocoa coordinates** (bottom-left origin);
/// conversion to the AX top-left space happens internally via `Geometry`.
final class WindowManager {
    static let shared = WindowManager()

    /// Remembers each window's pre-snap frame so "Restore" can undo a tile.
    /// Keyed by the AX element identity (stable per window via CFEqual/CFHash).
    private var restoreFrames: [AXWindowKey: NSRect] = [:]

    private init() {}

    // MARK: Frontmost window

    /// The focused window of the frontmost application, if any.
    func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &value
        )
        guard result == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    // MARK: Frame access

    /// Current frame of a window in **Cocoa coordinates**.
    func cocoaFrame(of window: AXUIElement) -> NSRect? {
        guard let axRect = axFrame(of: window) else { return nil }
        return Geometry.axToCocoa(axRect)
    }

    /// Move/resize a window using a **Cocoa-coordinate** rect.
    func setCocoaFrame(_ rect: NSRect, of window: AXUIElement) {
        setAXFrame(Geometry.cocoaToAX(rect), of: window)
    }

    // MARK: Restore memory

    /// Stores the window's current frame the first time it is snapped, so a
    /// later "Restore" can return it. No-op if a frame is already remembered.
    func rememberIfNeeded(_ window: AXUIElement, cocoaFrame: NSRect) {
        let key = AXWindowKey(element: window)
        if restoreFrames[key] == nil {
            restoreFrames[key] = cocoaFrame
        }
    }

    /// Whether a window has a remembered pre-snap frame.
    func hasRestoreFrame(for window: AXUIElement) -> Bool {
        restoreFrames[AXWindowKey(element: window)] != nil
    }

    /// Restores a window to its remembered pre-snap frame, if any.
    func restore(_ window: AXUIElement) {
        guard let frame = takeRestoreFrame(for: window) else { return }
        setCocoaFrame(frame, of: window)
    }

    /// Restores the remembered pre-snap size while keeping `point` at the same
    /// relative place inside the current frame. This makes drag-away restore feel
    /// anchored under the cursor instead of jumping back to the old position.
    func restoreSize(_ window: AXUIElement, keeping point: NSPoint, relativeTo currentFrame: NSRect) {
        guard let frame = takeRestoreFrame(for: window) else { return }

        let relativeX = normalizedOffset(point.x - currentFrame.minX, in: currentFrame.width)
        let relativeY = normalizedOffset(point.y - currentFrame.minY, in: currentFrame.height)
        let target = NSRect(
            x: point.x - relativeX * frame.width,
            y: point.y - relativeY * frame.height,
            width: frame.width,
            height: frame.height
        )
        setCocoaFrame(target, of: window)
    }

    /// Returns and clears the remembered pre-snap frame for a window.
    func takeRestoreFrame(for window: AXUIElement) -> NSRect? {
        let key = AXWindowKey(element: window)
        defer { restoreFrames[key] = nil }
        return restoreFrames[key]
    }

    // MARK: AX plumbing

    private func axFrame(of window: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let posValue, let sizeValue
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    private func setAXFrame(_ rect: CGRect, of window: AXUIElement) {
        var origin = rect.origin
        var size = rect.size

        // Size → position → size: some apps clamp position based on their current
        // size (and vice-versa), so we bracket the move to land reliably.
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
        if let posValue = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
    }

    private func normalizedOffset(_ value: CGFloat, in length: CGFloat) -> CGFloat {
        guard length > 0 else { return 0.5 }
        return min(max(value / length, 0), 1)
    }
}

/// Hashable wrapper so AX window elements can key a dictionary.
private struct AXWindowKey: Hashable {
    let element: AXUIElement

    static func == (lhs: AXWindowKey, rhs: AXWindowKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}
