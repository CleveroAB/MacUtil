import AppKit

/// A window-snapping target. Frame math is expressed in **Cocoa coordinates**
/// relative to a screen's `visibleFrame` (which already excludes the menu bar
/// and Dock).
enum SnapAction {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize, center
    case firstThird, centerThird, lastThird, firstTwoThirds, lastTwoThirds

    // Handled by SnapManager (need cross-screen / saved-state context), not pure math:
    case restore, nextDisplay, previousDisplay

    /// Computes the destination frame. Returns `nil` for actions handled by the
    /// manager (`restore`, `nextDisplay`, `previousDisplay`).
    ///
    /// - Parameters:
    ///   - vf: the target screen's `visibleFrame` (Cocoa coords).
    ///   - current: the window's current frame (Cocoa coords), used for `center`.
    func targetFrame(visibleFrame vf: NSRect, current: NSRect) -> NSRect? {
        let halfW = vf.width / 2
        let halfH = vf.height / 2
        let thirdW = vf.width / 3

        switch self {
        case .leftHalf:
            return NSRect(x: vf.minX, y: vf.minY, width: halfW, height: vf.height)
        case .rightHalf:
            return NSRect(x: vf.midX, y: vf.minY, width: halfW, height: vf.height)
        case .topHalf:
            return NSRect(x: vf.minX, y: vf.midY, width: vf.width, height: halfH)
        case .bottomHalf:
            return NSRect(x: vf.minX, y: vf.minY, width: vf.width, height: halfH)

        case .topLeft:
            return NSRect(x: vf.minX, y: vf.midY, width: halfW, height: halfH)
        case .topRight:
            return NSRect(x: vf.midX, y: vf.midY, width: halfW, height: halfH)
        case .bottomLeft:
            return NSRect(x: vf.minX, y: vf.minY, width: halfW, height: halfH)
        case .bottomRight:
            return NSRect(x: vf.midX, y: vf.minY, width: halfW, height: halfH)

        case .maximize:
            return vf
        case .center:
            return NSRect(
                x: vf.midX - current.width / 2,
                y: vf.midY - current.height / 2,
                width: current.width,
                height: current.height
            )

        case .firstThird:
            return NSRect(x: vf.minX, y: vf.minY, width: thirdW, height: vf.height)
        case .centerThird:
            return NSRect(x: vf.minX + thirdW, y: vf.minY, width: thirdW, height: vf.height)
        case .lastThird:
            return NSRect(x: vf.minX + 2 * thirdW, y: vf.minY, width: thirdW, height: vf.height)
        case .firstTwoThirds:
            return NSRect(x: vf.minX, y: vf.minY, width: 2 * thirdW, height: vf.height)
        case .lastTwoThirds:
            return NSRect(x: vf.minX + thirdW, y: vf.minY, width: 2 * thirdW, height: vf.height)

        case .restore, .nextDisplay, .previousDisplay:
            return nil
        }
    }
}
