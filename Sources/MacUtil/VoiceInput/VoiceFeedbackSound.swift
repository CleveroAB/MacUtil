import AppKit
import Foundation

enum VoiceFeedbackSound {
    private static let startSound = makeCue(
        duration: 0.16,
        startFrequency: 520,
        endFrequency: 760,
        volume: 0.28
    )
    private static let stopSound = makeCue(
        duration: 0.18,
        startFrequency: 700,
        endFrequency: 440,
        volume: 0.32
    )

    static func playStart() {
        play(startSound)
    }

    static func playStop(after delay: TimeInterval = 0) {
        guard delay > 0 else {
            play(stopSound)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            play(stopSound)
        }
    }

    private static func makeCue(
        duration: Double,
        startFrequency: Double,
        endFrequency: Double,
        volume: Float
    ) -> NSSound? {
        guard let data = wavData(
            duration: duration,
            startFrequency: startFrequency,
            endFrequency: endFrequency
        ) else {
            return nil
        }

        let sound = NSSound(data: data)
        sound?.volume = volume
        return sound
    }

    private static func play(_ sound: NSSound?) {
        guard let sound else { return }
        sound.stop()
        sound.currentTime = 0
        sound.play()
    }

    private static func wavData(
        duration: Double,
        startFrequency: Double,
        endFrequency: Double
    ) -> Data? {
        let sampleRate = 44_100
        let sampleCount = Int(duration * Double(sampleRate))
        guard sampleCount > 0 else { return nil }

        var samples = Data()
        samples.reserveCapacity(sampleCount * MemoryLayout<Int16>.size)

        for index in 0..<sampleCount {
            let progress = Double(index) / Double(max(sampleCount - 1, 1))
            let frequency = startFrequency + ((endFrequency - startFrequency) * progress)
            let t = Double(index) / Double(sampleRate)
            let attack = min(progress / 0.12, 1)
            let release = min((1 - progress) / 0.24, 1)
            let envelope = pow(max(0, min(attack, release)), 1.6)
            let primary = sin(2 * Double.pi * frequency * t)
            let overtone = 0.28 * sin(2 * Double.pi * frequency * 2.01 * t)
            let value = max(-1, min(1, (primary + overtone) * envelope * 0.46))
            append(Int16(value * Double(Int16.max)).littleEndian, to: &samples)
        }

        return wavContainer(samples: samples, sampleRate: sampleRate)
    }

    private static func wavContainer(samples: Data, sampleRate: Int) -> Data {
        var data = Data()
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = UInt32(sampleRate) * UInt32(blockAlign)

        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + samples.count).littleEndian, to: &data)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        append(UInt32(16).littleEndian, to: &data)
        append(UInt16(1).littleEndian, to: &data)
        append(channels.littleEndian, to: &data)
        append(UInt32(sampleRate).littleEndian, to: &data)
        append(byteRate.littleEndian, to: &data)
        append(blockAlign.littleEndian, to: &data)
        append(bitsPerSample.littleEndian, to: &data)
        data.append(contentsOf: "data".utf8)
        append(UInt32(samples.count).littleEndian, to: &data)
        data.append(samples)
        return data
    }

    private static func append<T>(_ value: T, to data: inout Data) {
        var value = value
        withUnsafeBytes(of: &value) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
