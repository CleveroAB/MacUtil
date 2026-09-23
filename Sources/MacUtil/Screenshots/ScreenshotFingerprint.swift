import CryptoKit
import CoreGraphics
import ImageIO
import Foundation

/// Hash decoded pixels, not file bytes: PNG/TIFF encodings and metadata differ.
struct ScreenshotFingerprint: Equatable {
    let width: Int
    let height: Int
    let digest: Data

    init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0,
              image.width <= 64_000_000 / image.height,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data else { return nil }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        width = image.width
        height = image.height
        digest = Data(SHA256.hash(data: Data(bytes: pixels, count: context.bytesPerRow * height)))
    }
}

struct ScreenshotSaveMatcher {
    struct Capture {
        let copiedAt: Date
        let pasteboardChangeCount: Int
        let fingerprint: ScreenshotFingerprint
        var wasPasted = false
    }

    private(set) var captures: [Capture] = []
    static let lifetime: TimeInterval = 30

    mutating func record(_ capture: Capture) {
        expire(at: capture.copiedAt)
        captures.append(capture)
    }

    mutating func markPasted(changeCount: Int, now: Date) {
        expire(at: now)
        guard let index = captures.lastIndex(where: { $0.pasteboardChangeCount == changeCount }) else { return }
        captures[index].wasPasted = true
    }

    /// A match can authorize at most one saved file. Ambiguity consumes all
    /// candidates without authorizing cleanup, so a later scan cannot guess.
    mutating func consume(fingerprint: ScreenshotFingerprint?, savedAt: Date) -> Capture? {
        guard let fingerprint else { return nil }
        let matches = captures.indices.filter {
            captures[$0].fingerprint == fingerprint &&
            savedAt >= captures[$0].copiedAt.addingTimeInterval(-1) &&
            savedAt <= captures[$0].copiedAt.addingTimeInterval(Self.lifetime)
        }
        let match = matches.count == 1 ? captures[matches[0]] : nil
        for index in matches.reversed() { captures.remove(at: index) }
        return match
    }

    mutating func expire(at now: Date) {
        captures.removeAll { now.timeIntervalSince($0.copiedAt) > Self.lifetime }
    }
}
