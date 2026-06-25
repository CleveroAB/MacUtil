import AppKit

/// Coordinate-system conversions — the single most common source of window-
/// management bugs on macOS.
///
/// - **Cocoa** (`NSScreen`, `NSWindow`): origin at the bottom-left of the
///   primary screen, Y increases **up**.
/// - **Accessibility / CoreGraphics** (`kAXPosition`, `CGWindowList`): origin at
///   the top-left of the primary screen, Y increases **down**.
///
/// The flip pivots on the height of the primary screen (`NSScreen.screens[0]`,
/// whose lower-left corner is the global origin).
enum Geometry {

    /// Height of the primary (menu-bar) screen, used as the flip pivot.
    private static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// Convert a top-left (AX/CG) rect to a bottom-left (Cocoa) rect.
    static func axToCocoa(_ rect: CGRect) -> NSRect {
        NSRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// Convert a bottom-left (Cocoa) rect to a top-left (AX/CG) rect.
    static func cocoaToAX(_ rect: NSRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// The screen whose frame contains the center of a Cocoa-space rect.
    static func screen(containing cocoaRect: NSRect) -> NSScreen? {
        let center = NSPoint(x: cocoaRect.midX, y: cocoaRect.midY)
        return screen(containing: center)
    }

    /// The screen whose frame contains a Cocoa-space point.
    static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSPointInRect(point, $0.frame) }
    }
}
