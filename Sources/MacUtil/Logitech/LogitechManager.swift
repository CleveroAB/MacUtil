import AppKit
import Darwin

final class LogitechManager {
    private let settings = Settings.shared
    private let queue = DispatchQueue(label: "MacUtil.Logitech", qos: .utility)
    private let devicesLock = NSLock()

    private var devices: [LogitechDeviceSnapshot] = []
    private let deviceMonitor = LogitechDeviceMonitor()
    private var discoveryRefresh: DispatchWorkItem?
    private var wakeObserver: NSObjectProtocol?
    private var isRunning = false
    private var lastAccessibility = false
    private(set) var discoveryIssue: String?
    private var captureSessions: [String: LogitechGestureCaptureSession] = [:]
    private var isRefreshing = false

    var onDevicesChanged: (() -> Void)?

    func start() {
        lastAccessibility = Permissions.hasAccessibility
        queue.sync { isRunning = true }
        deviceMonitor.onChange = { [weak self] in self?.scheduleDiscoveryRefresh() }
        discoveryIssue = deviceMonitor.start() ? nil : "Device access unavailable; check Input Monitoring"
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleDiscoveryRefresh() }
        refreshDevices()
    }

    func refreshPermissionState() {
        let granted = Permissions.hasAccessibility
        if discoveryIssue != nil {
            discoveryIssue = deviceMonitor.start() ? nil : "Device access unavailable; check Input Monitoring"
        }
        guard granted != lastAccessibility else { return }
        lastAccessibility = granted
        refreshDevices()
    }

    private func scheduleDiscoveryRefresh() {
        discoveryRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshDevices() }
        discoveryRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func stop() {
        discoveryRefresh?.cancel()
        discoveryRefresh = nil
        deviceMonitor.stop()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        queue.sync {
            isRunning = false
            for session in captureSessions.values { session.stop() }
            captureSessions.removeAll()
        }
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
            self.reconcileCurrentDevices()
        }
    }

    func sideButtonAction(for deviceID: String, button: LogitechSideButton) -> LogitechSideButtonAction {
        settings.logitechSideButtonAction(for: deviceID, button: button)
    }

    func setSideButtonAction(_ action: LogitechSideButtonAction, for deviceID: String, button: LogitechSideButton) {
        settings.setLogitechSideButtonAction(action, for: deviceID, button: button)
        queue.async { [weak self] in self?.reconcileCurrentDevices() }
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
        guard isRunning, !isRefreshing else { return }
        isRefreshing = true
        var latest = LogitechHID.enumerateDevices()
        isRefreshing = false

        reconcileCaptureSessions(with: &latest)
        devicesLock.lock()
        devices = latest
        devicesLock.unlock()

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

    private func reconcileCurrentDevices() {
        guard isRunning else { return }
        var latest = currentDevices()
        reconcileCaptureSessions(with: &latest)
        devicesLock.lock()
        devices = latest
        devicesLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onDevicesChanged?() }
    }

    private func reconcileCaptureSessions(with snapshots: inout [LogitechDeviceSnapshot]) {
        let onlineIDs = Set(snapshots.filter(\.isOnline).map(\.id))
        for id in Array(captureSessions.keys) where !onlineIDs.contains(id) {
            captureSessions.removeValue(forKey: id)?.stop()
        }
        for index in snapshots.indices {
            let device = snapshots[index]
            let config = LogitechControlConfiguration(
                gesture: device.supportsGestureButton && settings.logitechGestureAction(for: device.id) == .missionControl,
                sideActions: Dictionary(uniqueKeysWithValues: device.supportedSideButtons.map {
                    ($0, settings.logitechSideButtonAction(for: device.id, button: $0))
                })
            )
            let canRun = device.isOnline && Permissions.hasAccessibility && (config.gesture || !config.sideActions.isEmpty)
            if let session = captureSessions[device.id], !canRun || session.configuration != config {
                session.stop()
                captureSessions[device.id] = nil
            }
            guard canRun else {
                if !Permissions.hasAccessibility { snapshots[index].lastError = "Grant Accessibility to enable button actions" }
                continue
            }
            guard captureSessions[device.id] == nil else { continue }
            do {
                let session = LogitechGestureCaptureSession(route: device.route, configuration: config)
                try session.start()
                captureSessions[device.id] = session
                snapshots[index].lastError = nil
            } catch {
                snapshots[index].lastError = "Button capture: \(error.localizedDescription)"
                DebugLog.log("[MacUtil] Logitech capture failed: \(error.localizedDescription)")
            }
        }
    }
}

struct LogitechControlConfiguration: Equatable {
    let gesture: Bool
    let sideActions: [LogitechSideButton: LogitechSideButtonAction]
}

/// Each session receives reports from one physical channel and receiver slot.
struct LogitechButtonPresses {
    private var held: Set<UInt16> = []
    mutating func update(_ controls: [UInt16]) -> Set<UInt16> {
        let current = Set(controls.filter { $0 != 0 })
        defer { held = current }
        return current.subtracting(held)
    }
}

private final class LogitechGestureCaptureSession {
    let route: LogitechDeviceRoute
    let configuration: LogitechControlConfiguration
    private var presses = LogitechButtonPresses()
    private(set) var channel: LogitechHIDChannel?

    private var listenerID: Int?
    private var featureIndex: UInt8?
    private let stateLock = NSLock()
    private var isRunning = false
    private var gestureHeld = false
    private var heldSince: Date?
    private var dx = 0
    private var dy = 0
    private var fired = false

    init(route: LogitechDeviceRoute, configuration: LogitechControlConfiguration) {
        self.route = route
        self.configuration = configuration
    }

    func start() throws {
        let channel = try LogitechHID.openChannel(for: route)
        let featureIndex: UInt8
        do {
            featureIndex = try LogitechHID.armControls(route: route, channel: channel,
                gesture: configuration.gesture, sideButtons: Set(configuration.sideActions.keys))
        } catch {
            channel.close()
            throw error
        }

        stateLock.lock()
        self.channel = channel
        self.featureIndex = featureIndex
        isRunning = true
        stateLock.unlock()
        listenerID = channel.addListener { [weak self] message in
            self?.handle(message)
        }
    }

    func stop() {
        stateLock.lock()
        isRunning = false
        stateLock.unlock()
        if let channel, let listenerID {
            channel.removeListener(listenerID)
        }
        if let channel, let featureIndex {
            LogitechHID.disarmControls(route: route, featureIndex: featureIndex, channel: channel,
                gesture: configuration.gesture, sideButtons: Set(configuration.sideActions.keys))
        }
        channel?.close()
        stateLock.lock()
        channel = nil
        listenerID = nil
        featureIndex = nil
        stateLock.unlock()
    }

    private func handle(_ message: LogitechHIDMessage) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isRunning, let featureIndex,
              let event = LogitechHID.decodeGestureEvent(
                message,
                deviceIndex: route.deviceIndex,
                featureIndex: featureIndex
              ) else {
            return
        }

        switch event {
        case .buttons(let cids):
            let pressed = presses.update(cids)
            for (button, action) in configuration.sideActions where pressed.contains(button.controlID) {
                LogitechActionDispatcher.perform(action)
            }
            guard configuration.gesture else { return }
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
            event.post(tap: .cghidEventTap)
        }
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
