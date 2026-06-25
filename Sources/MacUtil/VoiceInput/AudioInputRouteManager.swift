import CoreAudio
import Foundation

final class AudioInputRouteManager {
    static let shared = AudioInputRouteManager()

    private init() {}

    func temporaryNonBluetoothInputLease() -> AudioInputRouteLease? {
        guard let current = defaultInputDevice(),
              let currentInfo = deviceInfo(for: current),
              currentInfo.isBluetooth else {
            return nil
        }

        guard let replacement = preferredReplacement(for: current, currentInfo: currentInfo) else {
            DebugLog.log("[MacUtil] voice: Bluetooth input active; no non-Bluetooth input found")
            return nil
        }

        guard setDefaultInputDevice(replacement.id) else {
            DebugLog.log("[MacUtil] voice: failed to switch input from \(currentInfo.name) to \(replacement.name)")
            return nil
        }

        DebugLog.log("[MacUtil] voice: temporarily using \(replacement.name) instead of Bluetooth input \(currentInfo.name)")
        return AudioInputRouteLease(originalDeviceID: current, originalName: currentInfo.name)
    }

    fileprivate func restoreDefaultInputDevice(_ deviceID: AudioDeviceID, name: String) {
        guard setDefaultInputDevice(deviceID) else {
            DebugLog.log("[MacUtil] voice: failed to restore input device \(name)")
            return
        }
        DebugLog.log("[MacUtil] voice: restored input device \(name)")
    }

    private func preferredReplacement(for current: AudioDeviceID, currentInfo: AudioDeviceInfo) -> AudioDeviceInfo? {
        let candidates = inputDevices()
            .filter { $0.id != current && $0.isUsableReplacement }
            .sorted { lhs, rhs in
                let lhsRank = lhs.preferenceRank(replacing: currentInfo)
                let rhsRank = rhs.preferenceRank(replacing: currentInfo)
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        if !candidates.isEmpty {
            DebugLog.log("[MacUtil] voice: non-Bluetooth input candidates \(candidates.map(\.logDescription).joined(separator: ", "))")
        }
        return candidates.first
    }

    private func inputDevices() -> [AudioDeviceInfo] {
        allDevices()
            .filter(hasInputStreams)
            .compactMap(deviceInfo)
    }

    private func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)

        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var devices = [AudioDeviceID](repeating: 0, count: count)
        let status = devices.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr else { return [] }
        return devices
    }

    private func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            return nil
        }
        return deviceID
    }

    private func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableDeviceID = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            size,
            &mutableDeviceID
        ) == noErr
    }

    private func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr
            && size >= MemoryLayout<AudioStreamID>.size
    }

    private func deviceInfo(for deviceID: AudioDeviceID) -> AudioDeviceInfo? {
        guard let name = deviceName(for: deviceID),
              let transportType = deviceTransportType(for: deviceID) else {
            return nil
        }
        return AudioDeviceInfo(id: deviceID, name: name, transportType: transportType)
    }

    private func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private func deviceTransportType(for deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType)
        guard status == noErr else { return nil }
        return transportType
    }
}

final class AudioInputRouteLease {
    private let originalDeviceID: AudioDeviceID
    private let originalName: String
    private var restored = false

    fileprivate init(originalDeviceID: AudioDeviceID, originalName: String) {
        self.originalDeviceID = originalDeviceID
        self.originalName = originalName
    }

    func restore() {
        guard !restored else { return }
        restored = true
        AudioInputRouteManager.shared.restoreDefaultInputDevice(originalDeviceID, name: originalName)
    }

    deinit {
        restore()
    }
}

private struct AudioDeviceInfo {
    let id: AudioDeviceID
    let name: String
    let transportType: UInt32

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    var isVirtual: Bool {
        transportType == kAudioDeviceTransportTypeVirtual
    }

    var isContinuity: Bool {
        transportType == kAudioDeviceTransportTypeContinuityCaptureWired
            || transportType == kAudioDeviceTransportTypeContinuityCaptureWireless
    }

    var isUsableReplacement: Bool {
        !isBluetooth && !isVirtual && !isContinuity
    }

    var logDescription: String {
        "\(name) [\(transportDescription)]"
    }

    func preferenceRank(replacing current: AudioDeviceInfo) -> Int {
        if isLikelyCompanionDevice(for: current) {
            return 0
        }

        switch transportType {
        case kAudioDeviceTransportTypeUSB:
            return 1
        case kAudioDeviceTransportTypeBuiltIn:
            return 2
        default:
            return 3
        }
    }

    private func isLikelyCompanionDevice(for current: AudioDeviceInfo) -> Bool {
        guard transportType == kAudioDeviceTransportTypeUSB else { return false }
        let currentTokens = Set(searchTokens(in: current.name))
        guard !currentTokens.isEmpty else { return false }
        return !currentTokens.isDisjoint(with: searchTokens(in: name))
    }

    private func searchTokens(in value: String) -> [String] {
        value
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 4 }
    }

    private var transportDescription: String {
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth:
            return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE:
            return "Bluetooth LE"
        case kAudioDeviceTransportTypeUSB:
            return "USB"
        case kAudioDeviceTransportTypeBuiltIn:
            return "Built-in"
        case kAudioDeviceTransportTypeVirtual:
            return "Virtual"
        case kAudioDeviceTransportTypeContinuityCaptureWired:
            return "Continuity"
        case kAudioDeviceTransportTypeContinuityCaptureWireless:
            return "Continuity"
        default:
            return "\(transportType)"
        }
    }
}
