import AppKit
import CoreGraphics

/// Quits regular running apps that have no open AX windows.
///
/// The shortcut intentionally uses a session event tap because macOS reserves
/// Command+Shift+Q for logout below the normal app menu layer.
final class WindowlessAppQuitter {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    var isActive: Bool {
        guard Permissions.hasAccessibility, let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }
    private var isChecking = false
    private var generation = 0
    private let queue = DispatchQueue(label: "MacUtil.WindowlessInspection", qos: .userInitiated)

    func start() {
        guard !isActive else { return }
        removeEventTap()
        guard Permissions.hasAccessibility else { return }
        installEventTap()

    }

    func stop() {
        generation &+= 1
        removeEventTap()
    }

    func quitWindowlessApps() {
        guard !isChecking, Permissions.hasAccessibility else { return }
        isChecking = true
        let token = generation
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != currentPID &&
            $0.bundleIdentifier != "com.apple.finder" && $0.bundleIdentifier != nil
        }
        // AX queries must not block the global keyboard event callback.
        queue.async { [weak self] in
            for app in apps where !app.isTerminated {
                guard Self.hasNoOpenWindows(pid: app.processIdentifier) else { continue }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isActive, self.generation == token, !app.isTerminated else { return }
                    let accepted = app.terminate()
                    DebugLog.log("[MacUtil] windowless-quit: \(app.localizedName ?? "App") accepted=\(accepted)")
                }
            }
            DispatchQueue.main.async { [weak self] in self?.isChecking = false }
        }
    }

    /// Unknown evidence always protects the app.
    static func canQuit(axWindowCount: Int?, hasCGWindow: Bool?) -> Bool {
        axWindowCount == 0 && hasCGWindow == false
    }

    private static func hasNoOpenWindows(pid: pid_t) -> Bool {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], windows.isEmpty,
              let allWindows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
        else { return false }
        // Protect windows on other Spaces and apps that under-report their AX windows.
        return canQuit(axWindowCount: windows.count, hasCGWindow: allWindows.contains {
            ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) &&
            ($0[kCGWindowLayer as String] as? Int) == 0
        })
    }

    // MARK: Event tap

    private func installEventTap() {
        let mask = UInt64(1) << CGEventType.keyDown.rawValue

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let quitter = Unmanaged<WindowlessAppQuitter>.fromOpaque(refcon).takeUnretainedValue()
            return quitter.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            DebugLog.log("[MacUtil] windowless-quit: event tap creation FAILED (grant Accessibility / Input Monitoring)")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLog.log("[MacUtil] windowless-quit: Command+Shift+Q event tap installed")
    }

    private func removeEventTap() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
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

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let matchesShortcut =
            keyCode == KeyCode.q &&
            flags.contains(.maskCommand) &&
            flags.contains(.maskShift) &&
            !flags.contains(.maskControl) &&
            !flags.contains(.maskAlternate)

        guard matchesShortcut else { return Unmanaged.passUnretained(event) }

        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { quitWindowlessApps() }
        return nil
    }
}
