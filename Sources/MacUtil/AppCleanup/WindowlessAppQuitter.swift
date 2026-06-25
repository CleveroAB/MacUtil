import AppKit
import CoreGraphics

/// Quits regular running apps that have no open AX windows.
///
/// The shortcut intentionally uses a session event tap because macOS reserves
/// Command+Shift+Q for logout below the normal app menu layer.
final class WindowlessAppQuitter {
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

    func quitWindowlessApps() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let visibleWindows = WindowEnumerator.list()
        let appsWithWindows = Set(visibleWindows.map(\.pid))
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular &&
            app.processIdentifier != currentPID &&
            app.bundleIdentifier != "com.apple.finder" &&
            app.bundleIdentifier != nil
        }

        var quitNames: [String] = []
        var failedNames: [String] = []
        var candidateNames: [String] = []
        for app in apps where !appsWithWindows.contains(app.processIdentifier) {
            let name = app.localizedName ?? app.bundleIdentifier ?? "\(app.processIdentifier)"
            candidateNames.append(name)
            if app.terminate() {
                quitNames.append(name)
            } else {
                failedNames.append(name)
            }
        }

        let windowedNames = visibleWindows.map { "\($0.appName):\($0.title)" }.joined(separator: " | ")
        DebugLog.log("[MacUtil] windowless-quit: windowed=[\(windowedNames)] candidates=[\(candidateNames.joined(separator: ", "))] quit=[\(quitNames.joined(separator: ", "))] failed=[\(failedNames.joined(separator: ", "))]")
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

        quitWindowlessApps()
        return nil
    }
}
