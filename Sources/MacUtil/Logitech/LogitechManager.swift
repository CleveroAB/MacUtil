import AppKit
import Darwin

final class LogitechManager {
    private let settings = Settings.shared
    private let queue = DispatchQueue(label: "MacUtil.Logitech", qos: .utility)
    private let devicesLock = NSLock()

    private var devices: [LogitechDeviceSnapshot] = []
    private var timer: DispatchSourceTimer?
    private var captureSessions: [String: LogitechGestureCaptureSession] = [:]
    private let sideButtonTap = LogitechSideButtonEventTap()
    private var isRefreshing = false

    var onDevicesChanged: (() -> Void)?

    func start() {
        sideButtonTap.actionProvider = { [weak self] button in
            self?.sideButtonActionForTap(button)
        }
        refreshDevices()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.refreshDevicesOnQueue()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {
            for session in captureSessions.values {
                session.stop()
            }
            captureSessions.removeAll()
        }
        stopSideButtonTap()
    }

    func refreshDevices() {
        queue.async { [weak self] in
            self?.refreshDevicesOnQueue()
        }
    }

    func currentDevices() -> [LogitechDeviceSnapshot] {
        devicesLock.lock()
        defer { devicesLock.unlock() }
        return devices
    }

    func device(withID id: String) -> LogitechDeviceSnapshot? {
        currentDevices().first { $0.id == id }
    }

    func gestureAction(for deviceID: String) -> LogitechGestureAction {
        settings.logitechGestureAction(for: deviceID)
    }

    func setGestureAction(_ action: LogitechGestureAction, for deviceID: String) {
        settings.setLogitechGestureAction(action, for: deviceID)
        queue.async { [weak self] in
            guard let self else { return }
            self.reconcileCaptureSessions(with: self.currentDevices())
        }
    }

    func sideButtonAction(for deviceID: String, button: LogitechSideButton) -> LogitechSideButtonAction {
        settings.logitechSideButtonAction(for: deviceID, button: button)
    }

    func setSideButtonAction(_ action: LogitechSideButtonAction, for deviceID: String, button: LogitechSideButton) {
        settings.setLogitechSideButtonAction(action, for: deviceID, button: button)
        updateSideButtonTap(with: currentDevices())
    }

    func setDPI(_ dpi: Int, for deviceID: String, completion: @escaping (Result<UInt16, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, let device = self.currentDevices().first(where: { $0.id == deviceID }) else {
                DispatchQueue.main.async { completion(.failure(LogitechHIDError.deviceNotFound)) }
                return
            }

            let target = device.dpi?.nearest(to: dpi) ?? UInt16(clamping: dpi)
            do {
                try LogitechHID.setDPI(
                    target,
                    route: device.route,
                    channel: self.captureSessions[deviceID]?.channel
                )
                self.settings.setLogitechDPI(Int(target), for: deviceID)
                self.updateDPI(target, for: deviceID)
                DispatchQueue.main.async { completion(.success(target)) }
                self.refreshDevicesOnQueue()
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func refreshDevicesOnQueue() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let latest = LogitechHID.enumerateDevices()
        isRefreshing = false

        devicesLock.lock()
        devices = latest
        devicesLock.unlock()

        reconcileCaptureSessions(with: latest)
        updateSideButtonTap(with: latest)
        DispatchQueue.main.async { [weak self] in
            self?.onDevicesChanged?()
        }
    }

    private func updateDPI(_ dpi: UInt16, for deviceID: String) {
        devicesLock.lock()
        if let index = devices.firstIndex(where: { $0.id == deviceID }),
           var info = devices[index].dpi {
            info.current = dpi
            devices[index].dpi = info
        }
        devicesLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.onDevicesChanged?()
        }
    }

    private func reconcileCaptureSessions(with snapshots: [LogitechDeviceSnapshot]) {
        let desired = snapshots.filter {
            $0.isOnline
                && $0.supportsGestureButton
                && settings.logitechGestureAction(for: $0.id) == .missionControl
        }

        let desiredIDs = Set(desired.map(\.id))
        let staleIDs = captureSessions.keys.filter { !desiredIDs.contains($0) }
        for id in staleIDs {
            captureSessions[id]?.stop()
            captureSessions.removeValue(forKey: id)
        }

        for device in desired where captureSessions[device.id] == nil {
            do {
                let session = LogitechGestureCaptureSession(route: device.route)
                try session.start()
                captureSessions[device.id] = session
            } catch {
                DebugLog.log("Logitech gesture capture failed for \(device.name): \(error.localizedDescription)")
            }
        }
    }

    private func sideButtonActionForTap(_ button: LogitechSideButton) -> LogitechSideButtonAction? {
        guard let deviceID = currentDevices().first(where: { $0.isOnline })?.id else {
            return nil
        }
        return settings.logitechSideButtonAction(for: deviceID, button: button)
    }

    private func updateSideButtonTap(with snapshots: [LogitechDeviceSnapshot]) {
        let shouldRun = snapshots.contains { $0.isOnline }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            shouldRun ? self.sideButtonTap.start() : self.sideButtonTap.stop()
        }
    }

    private func stopSideButtonTap() {
        if Thread.isMainThread {
            sideButtonTap.stop()
        } else {
            DispatchQueue.main.sync {
                sideButtonTap.stop()
            }
        }
    }
}

private final class LogitechGestureCaptureSession {
    let route: LogitechDeviceRoute
    private(set) var channel: LogitechHIDChannel?

    private var listenerID: Int?
    private var featureIndex: UInt8?
    private let stateLock = NSLock()
    private var gestureHeld = false
    private var heldSince: Date?
    private var dx = 0
    private var dy = 0
    private var fired = false

    init(route: LogitechDeviceRoute) {
        self.route = route
    }

    func start() throws {
        let channel = try LogitechHID.openChannel(for: route)
        let featureIndex = try LogitechHID.armGestureButton(route: route, channel: channel)

        self.channel = channel
        self.featureIndex = featureIndex
        listenerID = channel.addListener { [weak self] message in
            self?.handle(message)
        }
    }

    func stop() {
        if let channel, let listenerID {
            channel.removeListener(listenerID)
        }
        if let channel, let featureIndex {
            LogitechHID.disarmGestureButton(route: route, featureIndex: featureIndex, channel: channel)
        }
        channel?.close()
        channel = nil
        listenerID = nil
        featureIndex = nil
    }

    private func handle(_ message: LogitechHIDMessage) {
        guard let featureIndex,
              let event = LogitechHID.decodeGestureEvent(
                message,
                deviceIndex: route.deviceIndex,
                featureIndex: featureIndex
              ) else {
            return
        }

        stateLock.lock()
        defer { stateLock.unlock() }

        switch event {
        case .buttons(let cids):
            let isHeld = cids.contains(0x00c3)
            if isHeld && !gestureHeld {
                gestureHeld = true
                heldSince = Date()
                dx = 0
                dy = 0
                fired = false
            } else if !isHeld && gestureHeld {
                gestureHeld = false
                heldSince = nil
                if !fired {
                    fired = true
                    LogitechActionDispatcher.perform(.missionControl)
                }
            }

        case .rawXY(let rawDX, let rawDY):
            guard gestureHeld, !fired else { return }
            dx += Int(rawDX)
            dy += Int(rawDY)

            let heldLongEnough = heldSince.map { Date().timeIntervalSince($0) >= 0.16 } ?? false
            if heldLongEnough && max(abs(dx), abs(dy)) >= 80 {
                fired = true
                LogitechActionDispatcher.perform(.missionControl)
            }
        }
    }
}

private enum LogitechActionDispatcher {
    static func perform(_ action: LogitechGestureAction) {
        switch action {
        case .disabled:
            return
        case .missionControl:
            DispatchQueue.main.async {
                if !DockActionDispatcher.send("com.apple.expose.awake") {
                    postControlUpFallback()
                }
            }
        }
    }

    static func perform(_ action: LogitechSideButtonAction) {
        switch action {
        case .disabled:
            return
        case .browserBack:
            DispatchQueue.main.async {
                postSideButton(buttonNumber: 3)
            }
        case .browserForward:
            DispatchQueue.main.async {
                postSideButton(buttonNumber: 4)
            }
        }
    }

    private static func postControlUpFallback() {
        postKey(126, flags: .maskControl)
    }

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)

        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)

        usleep(12_000)

        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }

    private static func postSideButton(buttonNumber: Int64) {
        let source = CGEventSource(stateID: .hidSystemState)
        let location = CGEvent(source: source)?.location ?? .zero
        let button = CGMouseButton(rawValue: UInt32(buttonNumber)) ?? .center

        for eventType in [CGEventType.otherMouseDown, .otherMouseUp] {
            guard let event = CGEvent(
                mouseEventSource: source,
                mouseType: eventType,
                mouseCursorPosition: location,
                mouseButton: button
            ) else {
                continue
            }
            event.setIntegerValueField(.mouseEventButtonNumber, value: buttonNumber)
            event.setIntegerValueField(.eventSourceUserData, value: LogitechSideButtonEventTap.syntheticEventMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}

private final class LogitechSideButtonEventTap {
    static let syntheticEventMarker: Int64 = 0x4d555342

    var actionProvider: ((LogitechSideButton) -> LogitechSideButtonAction?)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isActive = false

    func start() {
        guard !isActive else { return }
        isActive = true
        installEventTap()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        removeEventTap()
    }

    private func installEventTap() {
        let mask = (UInt64(1) << CGEventType.otherMouseDown.rawValue)
            | (UInt64(1) << CGEventType.otherMouseUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<LogitechSideButtonEventTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            isActive = false
            DebugLog.log("[MacUtil] logitech: side-button event tap creation FAILED (grant Accessibility / Input Monitoring)")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type == .otherMouseDown || type == .otherMouseUp else {
            return Unmanaged.passUnretained(event)
        }

        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticEventMarker else {
            return Unmanaged.passUnretained(event)
        }

        let buttonNumber = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        guard let button = LogitechSideButton(mouseButtonNumber: buttonNumber),
              let action = actionProvider?(button) else {
            return Unmanaged.passUnretained(event)
        }

        if type == .otherMouseDown {
            LogitechActionDispatcher.perform(action)
        }
        return nil
    }
}

private enum DockActionDispatcher {
    private typealias CoreDockSendNotification = @convention(c) (CFString, Int32) -> Int32

    private static let coreDockSendNotification: CoreDockSendNotification? = {
        guard let handle = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            RTLD_LAZY
        ), let symbol = dlsym(handle, "CoreDockSendNotification") else {
            return nil
        }

        return unsafeBitCast(symbol, to: CoreDockSendNotification.self)
    }()

    static func send(_ notification: String) -> Bool {
        guard let coreDockSendNotification else { return false }
        let result = coreDockSendNotification(notification as CFString, 0)
        if result != 0 {
            DebugLog.log("[MacUtil] logitech: CoreDockSendNotification failed for \(notification), err=\(result)")
        }
        return result == 0
    }
}
