import AppKit
import XCTest
@testable import MacUtil

final class ScreenshotMatchingTests: XCTestCase {
    private func image(_ red: Int, type: NSBitmapImageRep.FileType = .png) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32))
        for y in 0..<8 {
            for x in 0..<8 {
                var pixel = [red, 30, 90, 255]
                bitmap.setPixel(&pixel, atX: x, y: y)
            }
        }
        return try XCTUnwrap(bitmap.representation(using: type, properties: [:]))
    }

    func testSameDimensionsDoNotMatchDifferentContent() throws {
        XCTAssertNotEqual(ScreenshotFingerprint(data: try image(20)), ScreenshotFingerprint(data: try image(200)))
    }

    func testEquivalentPNGAndTIFFMatch() throws {
        let png = try XCTUnwrap(ScreenshotFingerprint(data: image(80)))
        let tiff = try XCTUnwrap(ScreenshotFingerprint(data: image(80, type: .tiff)))
        XCTAssertEqual(png, tiff)
    }

    func testMissingOrInvalidImagesCannotAuthorizeCleanup() throws {
        XCTAssertNil(ScreenshotFingerprint(data: Data([1, 2, 3])))
        var matcher = ScreenshotSaveMatcher()
        let now = Date()
        matcher.record(.init(copiedAt: now, pasteboardChangeCount: 1,
                             fingerprint: try XCTUnwrap(ScreenshotFingerprint(data: image(80)))))
        XCTAssertNil(matcher.consume(fingerprint: nil, savedAt: now))
        XCTAssertEqual(matcher.captures.count, 1)
    }

    func testPastedMatchIsConsumedOnlyOnce() throws {
        let fingerprint = try XCTUnwrap(ScreenshotFingerprint(data: image(80)))
        let now = Date()
        var matcher = ScreenshotSaveMatcher()
        matcher.record(.init(copiedAt: now, pasteboardChangeCount: 7, fingerprint: fingerprint))
        matcher.markPasted(changeCount: 7, now: now)
        XCTAssertEqual(matcher.consume(fingerprint: fingerprint, savedAt: now)?.wasPasted, true)
        XCTAssertNil(matcher.consume(fingerprint: fingerprint, savedAt: now.addingTimeInterval(2)))
    }

    func testAmbiguousCapturesAreConsumedWithoutCleanup() throws {
        let fingerprint = try XCTUnwrap(ScreenshotFingerprint(data: image(80)))
        let now = Date()
        var matcher = ScreenshotSaveMatcher()
        for count in 1...2 {
            matcher.record(.init(copiedAt: now, pasteboardChangeCount: count, fingerprint: fingerprint))
            matcher.markPasted(changeCount: count, now: now)
        }
        XCTAssertNil(matcher.consume(fingerprint: fingerprint, savedAt: now))
        XCTAssertTrue(matcher.captures.isEmpty)
    }

    func testUnrelatedClipboardAndOldSavesNeverAuthorizeCleanup() throws {
        let fingerprint = try XCTUnwrap(ScreenshotFingerprint(data: image(80)))
        let now = Date()
        var matcher = ScreenshotSaveMatcher()
        matcher.record(.init(copiedAt: now, pasteboardChangeCount: 7, fingerprint: fingerprint))
        matcher.markPasted(changeCount: 8, now: now)
        XCTAssertNil(matcher.consume(fingerprint: fingerprint, savedAt: now.addingTimeInterval(31)))
        XCTAssertEqual(matcher.consume(fingerprint: fingerprint, savedAt: now)?.wasPasted, false)
    }
}

final class WindowSafetyTests: XCTestCase {
    func testUnknownOrExistingWindowsAlwaysProtectAppFromCleanup() {
        for count: Int? in [nil, 0, 1, 10] {
            for hasWindow: Bool? in [nil, false, true] {
                XCTAssertEqual(WindowlessAppQuitter.canQuit(axWindowCount: count, hasCGWindow: hasWindow),
                               count == 0 && hasWindow == false)
            }
        }
    }

    func testCrossDisplayPlacementFitsSizeAndOrigin() {
        let screens = [NSRect(x: -1920, y: -500, width: 1920, height: 1080),
                       NSRect(x: 0, y: 0, width: 800, height: 600)]
        for screen in screens {
            for frame in [NSRect(x: -3000, y: -2000, width: 3000, height: 2000),
                          NSRect(x: 1900, y: 1000, width: 500, height: 400)] {
                let fitted = Geometry.constrained(frame, to: screen)
                XCTAssertTrue(screen.contains(fitted))
                XCTAssertEqual(fitted.width, min(frame.width, screen.width))
                XCTAssertEqual(fitted.height, min(frame.height, screen.height))
            }
        }
    }

    func testPositionFailureIsNotMistakenForSuccessfulResize() {
        let target = NSRect(x: 100, y: 200, width: 800, height: 600)
        XCTAssertFalse(Geometry.approximatelyEqual(target, target.offsetBy(dx: 100, dy: 0)))
        XCTAssertTrue(Geometry.approximatelyEqual(target, target.offsetBy(dx: 1, dy: 1)))
        XCTAssertFalse(Geometry.approximatelyEqual(target, NSRect(x: 100, y: 200, width: 900, height: 600)))
    }
}

final class LogitechInputTests: XCTestCase {
    func testReceiverSlotAndFeatureMustMatchBeforeHandlingButtons() {
        let report = LogitechHIDMessage(reportID: 0x11, payload: [2, 5, 0, 0, 0x53])
        XCTAssertNil(LogitechHID.decodeGestureEvent(report, deviceIndex: 1, featureIndex: 5))
        XCTAssertNil(LogitechHID.decodeGestureEvent(report, deviceIndex: 2, featureIndex: 6))
        guard case .buttons(let controls) = LogitechHID.decodeGestureEvent(report, deviceIndex: 2, featureIndex: 5) else {
            return XCTFail("Expected this device's button report")
        }
        XCTAssertTrue(controls.contains(LogitechSideButton.back.controlID))
    }

    func testHeldButtonsFireOnceUntilReleasedAndDevicesAreIndependent() {
        var first = LogitechButtonPresses()
        var second = LogitechButtonPresses()
        XCTAssertEqual(first.update([0x53, 0]), [0x53])
        XCTAssertEqual(first.update([0x53, 0x56]), [0x56])
        XCTAssertEqual(second.update([0x53]), [0x53])
        XCTAssertTrue(first.update([]).isEmpty)
        XCTAssertEqual(first.update([0x53]), [0x53])
    }

    func testDirectDevicesOfSameModelKeepDistinctIdentities() {
        XCTAssertNotEqual(LogitechDeviceRoute.direct(deviceID: "1133:123:first").stableID,
                          LogitechDeviceRoute.direct(deviceID: "1133:123:second").stableID)
    }

    func testSideButtonDiversionDoesNotRequestUnsupportedRawXY() {
        XCTAssertEqual(LogitechHID.reportingBitfield(diverted: true, rawXY: nil), 0x03)
        XCTAssertEqual(LogitechHID.reportingBitfield(diverted: false, rawXY: nil), 0x02)
        XCTAssertEqual(LogitechHID.reportingBitfield(diverted: true, rawXY: true), 0x33)
    }
}
