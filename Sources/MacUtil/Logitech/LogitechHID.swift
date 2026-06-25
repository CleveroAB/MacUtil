import Foundation
import IOKit.hid

enum LogitechHIDError: Error, LocalizedError {
    case deviceNotFound
    case openFailed(IOReturn)
    case writeFailed(IOReturn)
    case noResponse
    case unsupportedResponse
    case unsupportedFeature(UInt16)
    case hidppError(UInt8)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "No matching Logitech HID++ device is connected."
        case .openFailed(let result):
            return "Could not open the HID device (\(LogitechHIDError.hex(result)))."
        case .writeFailed(let result):
            return "Could not write to the HID device (\(LogitechHIDError.hex(result)))."
        case .noResponse:
            return "The device did not respond."
        case .unsupportedResponse:
            return "The device returned an unsupported response."
        case .unsupportedFeature(let feature):
            return String(format: "The device does not support feature 0x%04x.", feature)
        case .hidppError(let code):
            return String(format: "The device returned HID++ error 0x%02x.", code)
        }
    }

    private static func hex(_ result: IOReturn) -> String {
        String(format: "0x%08x", UInt32(bitPattern: result))
    }
}

private struct LogitechHIDCandidate {
    let device: IOHIDDevice
    let vendorID: UInt16
    let productID: UInt16
    let usagePage: UInt16
    let usageID: UInt16
    let name: String
    let transport: String

    var isLongOnly: Bool {
        (usagePage == 0xff43 && usageID == 0x0202)
            || transport.localizedCaseInsensitiveContains("Bluetooth")
    }

    var isBoltReceiver: Bool {
        vendorID == 0x046d && productID == 0xc548
    }
}

struct LogitechHIDMessage {
    let reportID: UInt8
    let payload: [UInt8] // Excludes the report ID.

    var deviceIndex: UInt8 { payload[safe: 0] ?? 0 }
    var v20FeatureIndex: UInt8 { payload[safe: 1] ?? 0 }
    var v20FunctionSoftware: UInt8 { payload[safe: 2] ?? 0 }
    var v10SubID: UInt8 { payload[safe: 1] ?? 0 }

    static func parse(reportID: UInt8, bytes: [UInt8]) -> LogitechHIDMessage? {
        let normalized: [UInt8]
        if bytes.first == 0x10 || bytes.first == 0x11 {
            normalized = bytes
        } else if reportID == 0x10 || reportID == 0x11 {
            normalized = [reportID] + bytes
        } else {
            return nil
        }

        guard let first = normalized.first else { return nil }
        switch first {
        case 0x10 where normalized.count >= 7:
            return LogitechHIDMessage(reportID: 0x10, payload: Array(normalized[1..<7]))
        case 0x11 where normalized.count >= 20:
            return LogitechHIDMessage(reportID: 0x11, payload: Array(normalized[1..<20]))
        default:
            return nil
        }
    }

    func v20Payload() -> [UInt8] {
        extendedPayload(start: 3, length: 16)
    }

    func v10Payload() -> [UInt8] {
        extendedPayload(start: 2, length: 17)
    }

    private func extendedPayload(start: Int, length: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: length)
        guard payload.count > start else { return out }
        let count = min(length, payload.count - start)
        out[0..<count] = payload[start..<(start + count)]
        return out
    }
}

private final class LogitechPendingResponse {
    let predicate: (LogitechHIDMessage) -> Bool
    let semaphore = DispatchSemaphore(value: 0)
    var response: LogitechHIDMessage?

    init(predicate: @escaping (LogitechHIDMessage) -> Bool) {
        self.predicate = predicate
    }
}

private final class LogitechHIDRunLoopThread {
    static let shared = LogitechHIDRunLoopThread()

    private let thread: Thread
    private let runLoop: CFRunLoop
    private let mode: CFString = CFRunLoopMode.defaultMode.rawValue

    private init() {
        final class Box {
            var runLoop: CFRunLoop?
        }

        let box = Box()
        let ready = DispatchSemaphore(value: 0)
        thread = Thread {
            let current = CFRunLoopGetCurrent()
            let keepAlive = CFRunLoopTimerCreateWithHandler(
                kCFAllocatorDefault,
                CFAbsoluteTimeGetCurrent() + 3600,
                3600,
                0,
                0
            ) { _ in }
            CFRunLoopAddTimer(current, keepAlive, .defaultMode)

            box.runLoop = current
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "MacUtil Logitech HID"
        thread.start()
        ready.wait()
        runLoop = box.runLoop!
    }

    func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, mode, block)
        CFRunLoopWakeUp(runLoop)
    }

    func performSync(_ block: @escaping () -> Void) {
        if Thread.current == thread {
            block()
            return
        }

        let done = DispatchSemaphore(value: 0)
        perform {
            block()
            done.signal()
        }
        done.wait()
    }
}

final class LogitechHIDChannel {
    private let candidate: LogitechHIDCandidate
    private let inputReport = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private let sendLock = NSLock()
    private let pendingLock = NSLock()
    private let listenerLock = NSLock()

    private var pending: LogitechPendingResponse?
    private var listeners: [Int: (LogitechHIDMessage) -> Void] = [:]
    private var nextListenerID = 1
    private var isClosed = false

    var vendorID: UInt16 { candidate.vendorID }
    var productID: UInt16 { candidate.productID }
    var productName: String { candidate.name }
    var supportsShort: Bool { !candidate.isLongOnly }
    var supportsLong: Bool { true }

    fileprivate init(candidate: LogitechHIDCandidate) throws {
        self.candidate = candidate
        inputReport.initialize(repeating: 0, count: 64)

        var openResult: IOReturn = kIOReturnSuccess
        LogitechHIDRunLoopThread.shared.performSync {
            openResult = IOHIDDeviceOpen(candidate.device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard openResult == kIOReturnSuccess else { return }

            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(
                candidate.device,
                self.inputReport,
                64,
                { context, _, _, _, reportID, report, reportLength in
                    guard let context else { return }
                    let channel = Unmanaged<LogitechHIDChannel>
                        .fromOpaque(context)
                        .takeUnretainedValue()
                    channel.handleInputReport(
                        reportID: UInt8(reportID & 0xff),
                        report: report,
                        reportLength: reportLength
                    )
                },
                context
            )
            IOHIDDeviceScheduleWithRunLoop(candidate.device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }

        if openResult != kIOReturnSuccess {
            inputReport.deallocate()
            throw LogitechHIDError.openFailed(openResult)
        }
    }

    deinit {
        close()
        inputReport.deallocate()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true

        LogitechHIDRunLoopThread.shared.performSync {
            IOHIDDeviceUnscheduleFromRunLoop(self.candidate.device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(self.candidate.device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    func addListener(_ listener: @escaping (LogitechHIDMessage) -> Void) -> Int {
        listenerLock.lock()
        defer { listenerLock.unlock() }
        let id = nextListenerID
        nextListenerID += 1
        listeners[id] = listener
        return id
    }

    func removeListener(_ id: Int) {
        listenerLock.lock()
        listeners.removeValue(forKey: id)
        listenerLock.unlock()
    }

    func sendV20(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        functionID: UInt8,
        params: [UInt8],
        long: Bool = false,
        timeout: TimeInterval = 1.5
    ) throws -> [UInt8] {
        let softwareID: UInt8 = 0x01
        let functionSoftware = ((functionID & 0x0f) << 4) | softwareID
        let requestPayload = [deviceIndex, featureIndex, functionSoftware]

        let response = try send(
            reportID: long || !supportsShort ? 0x11 : 0x10,
            payload: requestPayload + padded(params, length: long || !supportsShort ? 16 : 3),
            timeout: timeout
        ) { message in
            guard message.deviceIndex == deviceIndex else { return false }

            let responseFeature = message.v20FeatureIndex
            let responseFunctionSoftware = message.v20FunctionSoftware

            if responseFeature == featureIndex && responseFunctionSoftware == functionSoftware {
                return true
            }

            if responseFeature == 0xff,
               responseFunctionSoftware == featureIndex,
               message.v20Payload()[0] == functionSoftware {
                return true
            }

            return false
        }

        if response.v20FeatureIndex == 0xff {
            throw LogitechHIDError.hidppError(response.v20Payload()[1])
        }

        return response.v20Payload()
    }

    func readRegister(deviceIndex: UInt8, address: UInt8, params: [UInt8]) throws -> [UInt8] {
        let payload = try sendV10(
            deviceIndex: deviceIndex,
            subID: 0x81,
            address: address,
            params: params,
            timeout: 1.5
        ).v10Payload()
        return Array(payload[1...3])
    }

    func writeRegister(deviceIndex: UInt8, address: UInt8, params: [UInt8]) throws {
        _ = try sendV10(
            deviceIndex: deviceIndex,
            subID: 0x80,
            address: address,
            params: params,
            timeout: 1.5
        )
    }

    func readLongRegister(deviceIndex: UInt8, address: UInt8, params: [UInt8]) throws -> [UInt8] {
        let payload = try sendV10(
            deviceIndex: deviceIndex,
            subID: 0x83,
            address: address,
            params: params,
            timeout: 1.5
        ).v10Payload()
        return Array(payload[1...16])
    }

    private func sendV10(
        deviceIndex: UInt8,
        subID: UInt8,
        address: UInt8,
        params: [UInt8],
        timeout: TimeInterval
    ) throws -> LogitechHIDMessage {
        let response = try send(
            reportID: 0x10,
            payload: [deviceIndex, subID, address] + padded(params, length: 3),
            timeout: timeout
        ) { message in
            guard message.payload.count >= 4,
                  message.payload[0] == deviceIndex else { return false }

            return (message.payload[1] == subID && message.payload[2] == address)
                || (message.payload[1] == 0x8f && message.payload[2] == subID && message.payload[3] == address)
        }

        if response.v10SubID == 0x8f {
            throw LogitechHIDError.hidppError(response.v10Payload()[2])
        }
        return response
    }

    private func send(
        reportID: UInt8,
        payload: [UInt8],
        timeout: TimeInterval,
        predicate: @escaping (LogitechHIDMessage) -> Bool
    ) throws -> LogitechHIDMessage {
        sendLock.lock()
        defer { sendLock.unlock() }

        let expectedLength = reportID == 0x10 ? 7 : 20
        let fullReport = [reportID] + padded(payload, length: expectedLength - 1)
        let pending = LogitechPendingResponse(predicate: predicate)

        pendingLock.lock()
        self.pending = pending
        pendingLock.unlock()

        let result = fullReport.withUnsafeBufferPointer { buffer -> IOReturn in
            guard let base = buffer.baseAddress else { return kIOReturnBadArgument }
            return IOHIDDeviceSetReport(
                candidate.device,
                kIOHIDReportTypeOutput,
                CFIndex(reportID),
                base,
                CFIndex(fullReport.count)
            )
        }

        if result != kIOReturnSuccess {
            clearPending(pending)
            throw LogitechHIDError.writeFailed(result)
        }

        let waitResult = pending.semaphore.wait(timeout: .now() + timeout)
        clearPending(pending)

        guard waitResult == .success, let response = pending.response else {
            throw LogitechHIDError.noResponse
        }
        return response
    }

    private func clearPending(_ pending: LogitechPendingResponse) {
        pendingLock.lock()
        if self.pending === pending {
            self.pending = nil
        }
        pendingLock.unlock()
    }

    private func handleInputReport(reportID: UInt8, report: UnsafeMutablePointer<UInt8>, reportLength: CFIndex) {
        let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
        guard let message = LogitechHIDMessage.parse(reportID: reportID, bytes: bytes) else { return }

        var matched = false
        pendingLock.lock()
        if let pending, pending.predicate(message) {
            pending.response = message
            matched = true
            pending.semaphore.signal()
        }
        pendingLock.unlock()

        guard !matched else { return }

        listenerLock.lock()
        let currentListeners = Array(listeners.values)
        listenerLock.unlock()

        for listener in currentListeners {
            listener(message)
        }
    }
}

enum LogitechHID {
    static func enumerateDevices() -> [LogitechDeviceSnapshot] {
        var snapshots: [LogitechDeviceSnapshot] = []
        let candidateList = candidates()

        for candidate in candidateList {
            autoreleasepool {
                guard let channel = try? LogitechHIDChannel(candidate: candidate) else {
                    return
                }
                defer { channel.close() }

                if candidate.isBoltReceiver {
                    snapshots.append(contentsOf: probeBoltReceiver(channel))
                } else if let direct = probeDirectDevice(channel, candidate: candidate) {
                    snapshots.append(direct)
                }
            }
        }

        return snapshots.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func openChannel(for route: LogitechDeviceRoute) throws -> LogitechHIDChannel {
        let available = candidates()
        var fallbackBolt: LogitechHIDChannel?

        for candidate in available {
            switch route {
            case .direct(let vendorID, let productID):
                guard candidate.vendorID == vendorID, candidate.productID == productID else { continue }
                return try LogitechHIDChannel(candidate: candidate)

            case .bolt(let receiverID, _):
                guard candidate.isBoltReceiver else { continue }
                let channel = try LogitechHIDChannel(candidate: candidate)
                if let uniqueID = try? receiverUniqueID(channel), uniqueID == receiverID {
                    fallbackBolt?.close()
                    return channel
                }
                if receiverID.hasPrefix("receiver:") {
                    fallbackBolt?.close()
                    return channel
                }
                if fallbackBolt == nil {
                    fallbackBolt = channel
                } else {
                    channel.close()
                }
            }
        }

        if case .bolt = route, let fallbackBolt {
            return fallbackBolt
        }
        throw LogitechHIDError.deviceNotFound
    }

    static func setDPI(_ dpi: UInt16, route: LogitechDeviceRoute, channel existingChannel: LogitechHIDChannel? = nil) throws {
        let channel: LogitechHIDChannel
        var shouldClose = false
        if let existingChannel {
            channel = existingChannel
        } else {
            channel = try openChannel(for: route)
            shouldClose = true
        }
        defer {
            if shouldClose { channel.close() }
        }

        guard let featureIndex = try featureIndex(0x2201, deviceIndex: route.deviceIndex, channel: channel) else {
            throw LogitechHIDError.unsupportedFeature(0x2201)
        }

        let bytes = dpi.bigEndianBytes
        _ = try channel.sendV20(
            deviceIndex: route.deviceIndex,
            featureIndex: featureIndex,
            functionID: 3,
            params: [0, bytes[0], bytes[1]]
        )
    }

    static func armGestureButton(route: LogitechDeviceRoute, channel: LogitechHIDChannel) throws -> UInt8 {
        guard let featureIndex = try featureIndex(0x1b04, deviceIndex: route.deviceIndex, channel: channel) else {
            throw LogitechHIDError.unsupportedFeature(0x1b04)
        }

        let controls = try reprogrammableControls(deviceIndex: route.deviceIndex, featureIndex: featureIndex, channel: channel)
        guard controls.contains(where: { $0.cid == 0x00c3 && $0.supportsRawXY }) else {
            throw LogitechHIDError.unsupportedFeature(0x1b04)
        }

        try setCIDReporting(0x00c3, diverted: true, rawXY: true, deviceIndex: route.deviceIndex, featureIndex: featureIndex, channel: channel)
        return featureIndex
    }

    static func disarmGestureButton(route: LogitechDeviceRoute, featureIndex: UInt8, channel: LogitechHIDChannel) {
        try? setCIDReporting(0x00c3, diverted: false, rawXY: false, deviceIndex: route.deviceIndex, featureIndex: featureIndex, channel: channel)
    }

    static func decodeGestureEvent(_ message: LogitechHIDMessage, deviceIndex: UInt8, featureIndex: UInt8) -> LogitechGestureRawEvent? {
        guard message.deviceIndex == deviceIndex,
              message.v20FeatureIndex == featureIndex,
              message.v20FunctionSoftware & 0x0f == 0 else {
            return nil
        }

        let functionID = message.v20FunctionSoftware >> 4
        let payload = message.v20Payload()
        switch functionID {
        case 0:
            return .buttons([
                UInt16(bigEndianBytes: payload[0], payload[1]),
                UInt16(bigEndianBytes: payload[2], payload[3]),
                UInt16(bigEndianBytes: payload[4], payload[5]),
                UInt16(bigEndianBytes: payload[6], payload[7]),
            ])
        case 1:
            return .rawXY(
                dx: Int16(bigEndianBytes: payload[0], payload[1]),
                dy: Int16(bigEndianBytes: payload[2], payload[3])
            )
        default:
            return nil
        }
    }

    private static func probeBoltReceiver(_ channel: LogitechHIDChannel) -> [LogitechDeviceSnapshot] {
        let receiverID = (try? receiverUniqueID(channel)) ?? String(format: "receiver:%04x:%04x", channel.vendorID, channel.productID)
        var devices: [LogitechDeviceSnapshot] = []

        for slot in UInt8(1)...UInt8(6) {
            guard let pairing = try? channel.readLongRegister(
                deviceIndex: 0xff,
                address: 0xb5,
                params: [0x50 + slot, 0, 0]
            ) else {
                continue
            }

            let online = pairing.indices.contains(1) && (pairing[1] & 0x40) == 0
            guard online else { continue }

            let name = (try? boltDeviceName(channel, slot: slot)) ?? "Logitech Device \(slot)"
            let route = LogitechDeviceRoute.bolt(receiverID: receiverID, slot: slot)
            devices.append(probePeripheral(name: name, route: route, channel: channel, online: true))
        }

        return devices
    }

    private static func probeDirectDevice(_ channel: LogitechHIDChannel, candidate: LogitechHIDCandidate) -> LogitechDeviceSnapshot? {
        let route = LogitechDeviceRoute.direct(vendorID: candidate.vendorID, productID: candidate.productID)
        let snapshot = probePeripheral(name: candidate.name, route: route, channel: channel, online: true)

        // Filter receiver secondary interfaces that answer a little HID++ but are
        // not configurable peripherals.
        if snapshot.batteryPercentage == nil,
           snapshot.dpi == nil,
           !snapshot.supportsGestureButton,
           snapshot.lastError == nil {
            return nil
        }

        return snapshot
    }

    private static func probePeripheral(
        name: String,
        route: LogitechDeviceRoute,
        channel: LogitechHIDChannel,
        online: Bool
    ) -> LogitechDeviceSnapshot {
        do {
            _ = try channel.sendV20(deviceIndex: route.deviceIndex, featureIndex: 0, functionID: 1, params: [0, 0, 0])
        } catch {
            return LogitechDeviceSnapshot(
                name: name,
                route: route,
                batteryPercentage: nil,
                dpi: nil,
                supportsGestureButton: false,
                isOnline: online,
                lastError: error.localizedDescription
            )
        }

        let battery = (try? readBatteryPercentage(deviceIndex: route.deviceIndex, channel: channel)).flatMap { $0 }
        let dpi = try? readDPIInfo(deviceIndex: route.deviceIndex, channel: channel)
        let supportsGesture = (try? gestureButtonIsSupported(deviceIndex: route.deviceIndex, channel: channel)) ?? false

        return LogitechDeviceSnapshot(
            name: name,
            route: route,
            batteryPercentage: battery,
            dpi: dpi,
            supportsGestureButton: supportsGesture,
            isOnline: online,
            lastError: nil
        )
    }

    private static func receiverUniqueID(_ channel: LogitechHIDChannel) throws -> String {
        let raw = try channel.readLongRegister(deviceIndex: 0xff, address: 0xfb, params: [0, 0, 0])
        return String(decoding: raw, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\0")))
    }

    private static func boltDeviceName(_ channel: LogitechHIDChannel, slot: UInt8) throws -> String {
        let response = try channel.readLongRegister(deviceIndex: 0xff, address: 0xb5, params: [0x60 + slot, 0x01, 0])
        let length = min(Int(response[safe: 2] ?? 0), 13)
        guard length > 0, response.count >= 3 + length else {
            throw LogitechHIDError.unsupportedResponse
        }
        return String(decoding: response[3..<(3 + length)], as: UTF8.self)
    }

    private static func readBatteryPercentage(deviceIndex: UInt8, channel: LogitechHIDChannel) throws -> Int? {
        guard let index = try featureIndex(0x1004, deviceIndex: deviceIndex, channel: channel) else {
            return nil
        }
        let payload = try channel.sendV20(deviceIndex: deviceIndex, featureIndex: index, functionID: 1, params: [0, 0, 0])
        let percentage = Int(payload[0])
        return (0...100).contains(percentage) ? percentage : nil
    }

    private static func readDPIInfo(deviceIndex: UInt8, channel: LogitechHIDChannel) throws -> LogitechDPIInfo? {
        guard let index = try featureIndex(0x2201, deviceIndex: deviceIndex, channel: channel) else {
            return nil
        }

        let listPayload = try channel.sendV20(deviceIndex: deviceIndex, featureIndex: index, functionID: 1, params: [0, 0, 0])
        let values = try parseDPIList(Array(listPayload.dropFirst()))
        let currentPayload = try channel.sendV20(deviceIndex: deviceIndex, featureIndex: index, functionID: 2, params: [0, 0, 0])
        let current = UInt16(bigEndianBytes: currentPayload[1], currentPayload[2])
        return LogitechDPIInfo(current: current, values: values)
    }

    private static func featureIndex(_ featureID: UInt16, deviceIndex: UInt8, channel: LogitechHIDChannel) throws -> UInt8? {
        let bytes = featureID.bigEndianBytes
        let payload = try channel.sendV20(
            deviceIndex: deviceIndex,
            featureIndex: 0,
            functionID: 0,
            params: [bytes[0], bytes[1], 0]
        )
        return payload[0] == 0 ? nil : payload[0]
    }

    private static func gestureButtonIsSupported(deviceIndex: UInt8, channel: LogitechHIDChannel) throws -> Bool {
        guard let index = try featureIndex(0x1b04, deviceIndex: deviceIndex, channel: channel) else {
            return false
        }
        return try reprogrammableControls(deviceIndex: deviceIndex, featureIndex: index, channel: channel)
            .contains { $0.cid == 0x00c3 && $0.supportsRawXY }
    }

    private static func reprogrammableControls(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        channel: LogitechHIDChannel
    ) throws -> [LogitechControlInfo] {
        let countPayload = try channel.sendV20(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            functionID: 0,
            params: Array(repeating: 0, count: 16),
            long: true
        )
        let count = Int(countPayload[0])
        guard count > 0 else { return [] }

        var controls: [LogitechControlInfo] = []
        for index in 0..<count {
            var params = [UInt8](repeating: 0, count: 16)
            params[0] = UInt8(index)
            let payload = try channel.sendV20(
                deviceIndex: deviceIndex,
                featureIndex: featureIndex,
                functionID: 1,
                params: params,
                long: true
            )
            controls.append(LogitechControlInfo(
                cid: UInt16(bigEndianBytes: payload[0], payload[1]),
                flags: UInt16(payload[4]) | (UInt16(payload[8]) << 8)
            ))
        }
        return controls
    }

    private static func setCIDReporting(
        _ cid: UInt16,
        diverted: Bool,
        rawXY: Bool,
        deviceIndex: UInt8,
        featureIndex: UInt8,
        channel: LogitechHIDChannel
    ) throws {
        let cidBytes = cid.bigEndianBytes
        var params = [UInt8](repeating: 0, count: 16)
        params[0] = cidBytes[0]
        params[1] = cidBytes[1]
        params[2] = reportingBitfield(diverted: diverted, rawXY: rawXY)
        _ = try channel.sendV20(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            functionID: 3,
            params: params,
            long: true
        )
    }

    private static func reportingBitfield(diverted: Bool, rawXY: Bool) -> UInt8 {
        let divertedFlag: UInt8 = 0x01
        let rawXYFlag: UInt8 = 0x10
        var field: UInt8 = 0

        if diverted { field |= divertedFlag }
        field |= divertedFlag << 1

        if rawXY { field |= rawXYFlag }
        field |= rawXYFlag << 1

        return field
    }

    private static func parseDPIList(_ bytes: [UInt8]) throws -> [UInt16] {
        var values: [UInt16] = []
        var offset = 0

        while offset + 1 < bytes.count {
            let value = UInt16(bigEndianBytes: bytes[offset], bytes[offset + 1])
            if value == 0 { break }

            if value >> 13 == 0b111 {
                let step = value & 0x1fff
                guard step > 0,
                      offset + 3 < bytes.count,
                      let start = values.last else {
                    throw LogitechHIDError.unsupportedResponse
                }

                let last = UInt16(bigEndianBytes: bytes[offset + 2], bytes[offset + 3])
                guard last >= start else { throw LogitechHIDError.unsupportedResponse }

                var next = UInt32(start) + UInt32(step)
                while next < UInt32(last) {
                    values.append(UInt16(next))
                    next += UInt32(step)
                }
                values.append(last)
                offset += 4
            } else {
                values.append(value)
                offset += 2
            }
        }

        let unique = Array(Set(values)).sorted()
        guard !unique.isEmpty else { throw LogitechHIDError.unsupportedResponse }
        return unique
    }

    private static func candidates() -> [LogitechHIDCandidate] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x046d] as CFDictionary)

        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return []
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let copiedDevices = IOHIDManagerCopyDevices(manager) else { return [] }
        let devices = copiedDevices as NSSet

        return devices.compactMap { element in
            let device = element as! IOHIDDevice
            guard let vendorID = uint16Property(device, kIOHIDVendorIDKey),
                  let productID = uint16Property(device, kIOHIDProductIDKey),
                  vendorID == 0x046d else {
                return nil
            }

            let usage = hidppUsage(for: device)
            guard isHIDPPCollection(usagePage: usage.page, usageID: usage.id) else {
                return nil
            }

            let name = stringProperty(device, kIOHIDProductKey)?.nilIfEmpty ?? "Logitech Device"
            return LogitechHIDCandidate(
                device: device,
                vendorID: vendorID,
                productID: productID,
                usagePage: usage.page,
                usageID: usage.id,
                name: name,
                transport: stringProperty(device, kIOHIDTransportKey) ?? ""
            )
        }
    }

    private static func isHIDPPCollection(usagePage: UInt16, usageID: UInt16) -> Bool {
        (usagePage == 0xff00 && usageID == 0x0002)
            || (usagePage == 0xff43 && usageID == 0x0202)
            || (usagePage == 0xff43 && usageID == 0x0602)
    }

    private static func hidppUsage(for device: IOHIDDevice) -> (page: UInt16, id: UInt16) {
        for pair in usagePairs(device) {
            if isHIDPPCollection(usagePage: pair.page, usageID: pair.id) {
                return pair
            }
        }

        let page = uint16Property(device, kIOHIDDeviceUsagePageKey)
            ?? uint16Property(device, kIOHIDPrimaryUsagePageKey)
            ?? 0
        let id = uint16Property(device, kIOHIDDeviceUsageKey)
            ?? uint16Property(device, kIOHIDPrimaryUsageKey)
            ?? 0
        return (page, id)
    }

    private static func usagePairs(_ device: IOHIDDevice) -> [(page: UInt16, id: UInt16)] {
        guard let rawPairs = IOHIDDeviceGetProperty(device, "DeviceUsagePairs" as CFString) as? [[String: Any]] else {
            return []
        }

        return rawPairs.compactMap { pair in
            guard let page = pair["DeviceUsagePage"] as? NSNumber,
                  let usage = pair["DeviceUsage"] as? NSNumber else {
                return nil
            }
            return (
                UInt16(truncatingIfNeeded: page.intValue),
                UInt16(truncatingIfNeeded: usage.intValue)
            )
        }
    }

    private static func uint16Property(_ device: IOHIDDevice, _ key: String) -> UInt16? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber else { return nil }
        return UInt16(truncatingIfNeeded: value.intValue)
    }

    private static func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}

private struct LogitechControlInfo {
    let cid: UInt16
    let flags: UInt16

    var supportsRawXY: Bool {
        flags & 0x0100 != 0
    }
}

enum LogitechGestureRawEvent {
    case buttons([UInt16])
    case rawXY(dx: Int16, dy: Int16)
}

private func padded(_ bytes: [UInt8], length: Int) -> [UInt8] {
    if bytes.count == length { return bytes }
    if bytes.count > length { return Array(bytes.prefix(length)) }
    return bytes + Array(repeating: 0, count: length - bytes.count)
}

private extension UInt16 {
    var bigEndianBytes: [UInt8] {
        [UInt8((self >> 8) & 0xff), UInt8(self & 0xff)]
    }

    init(bigEndianBytes high: UInt8, _ low: UInt8) {
        self = (UInt16(high) << 8) | UInt16(low)
    }
}

private extension Int16 {
    init(bigEndianBytes high: UInt8, _ low: UInt8) {
        self = Int16(bitPattern: UInt16(bigEndianBytes: high, low))
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
