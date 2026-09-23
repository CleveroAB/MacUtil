import AppKit
import XCTest
@testable import MacUtil

final class WindowDragMotionTests: XCTestCase {
    private let initial = NSRect(x: 200, y: 200, width: 600, height: 400)

    func testStationaryWindowDoesNotSnapDuringContentOrNotificationDrag() {
        var motion = WindowDragMotion(frameAtStart: initial)
        for _ in 0..<3 { XCTAssertFalse(motion.observe(initial)) }
    }

    func testActualWindowMoveCanSnap() {
        var motion = WindowDragMotion(frameAtStart: initial)
        XCTAssertFalse(motion.observe(initial.offsetBy(dx: 1, dy: 1)))
        XCTAssertTrue(motion.observe(initial.offsetBy(dx: 20, dy: 0)))
    }

    func testResizingAnyEdgeOrCornerNeverSnaps() {
        // Includes top/left resizing, which changes the origin as well as size.
        for dx in [-40.0, 0, 40] {
            for dy in [-40.0, 0, 40] where dx != 0 || dy != 0 {
                var motion = WindowDragMotion(frameAtStart: initial)
                let resized = NSRect(x: initial.minX + min(dx, 0), y: initial.minY + min(dy, 0),
                                     width: initial.width + abs(dx), height: initial.height + abs(dy))
                XCTAssertFalse(motion.observe(resized))
                XCTAssertFalse(motion.observe(resized.offsetBy(dx: 100, dy: 100)))
            }
        }
    }

    func testResizeRemainsDisqualifiedAfterReturningToOriginalSize() {
        var motion = WindowDragMotion(frameAtStart: initial)
        XCTAssertFalse(motion.observe(NSRect(x: 200, y: 200, width: 620, height: 400)))
        XCTAssertFalse(motion.observe(initial.offsetBy(dx: 100, dy: 0)))
    }

    func testResizeAfterMoveCancelsPendingSnapIncludingOnRelease() {
        var motion = WindowDragMotion(frameAtStart: initial)
        XCTAssertTrue(motion.observe(initial.offsetBy(dx: 100, dy: 0)))
        XCTAssertFalse(motion.observe(NSRect(x: 300, y: 200, width: 620, height: 400)))
    }

    func testMacUtilRestoreAllowsContinuedMoveButNotSubsequentResize() {
        var motion = WindowDragMotion(frameAtStart: initial)
        XCTAssertTrue(motion.observe(initial.offsetBy(dx: 20, dy: 0)))
        let restored = NSRect(x: 220, y: 200, width: 500, height: 300)
        motion.acceptRestoredFrame(restored)
        XCTAssertTrue(motion.observe(restored.offsetBy(dx: 50, dy: 0)))
        XCTAssertFalse(motion.observe(NSRect(x: 270, y: 200, width: 520, height: 300)))
    }

    func testNewGestureDoesNotInheritResizeRejection() {
        var previous = WindowDragMotion(frameAtStart: initial)
        let resized = NSRect(x: 200, y: 200, width: 700, height: 400)
        XCTAssertFalse(previous.observe(resized))
        var next = WindowDragMotion(frameAtStart: resized)
        XCTAssertTrue(next.observe(resized.offsetBy(dx: 20, dy: 0)))
    }
}
