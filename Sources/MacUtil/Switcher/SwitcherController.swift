import AppKit
import ApplicationServices
import CoreGraphics

/// Drives the alt-tab-style switcher, bound to **⌘Tab** to replace the macOS app
/// switcher.
///
/// macOS reserves ⌘Tab below the Carbon hotkey layer, so we install a
/// session-level `CGEventTap` that intercepts ⌘Tab / ⌘⇧Tab (plus Esc and ←/→
/// while open), swallows them so the system switcher never appears, and commits
/// when ⌘ is released. The tap is event-driven (only runs on key events), so
/// idle cost stays at zero. Requires Accessibility.
///
/// To avoid an icon→preview flicker, thumbnails are captured **before** the panel
/// is shown, so every card renders its preview from the first frame. A quick
/// ⌘Tab-and-release switches immediately without waiting for capture.
final class SwitcherController {
    private let panel = SwitcherPanel()
    private var windows: [SwitchWindow] = []
    private var thumbnails: [CGWindowID: NSImage] = [:]
    private var selection = 0
    private var visible = false      // panel is on screen
    private var opening = false      // capturing thumbnails before the first show
    private var pendingSteps = 0     // net cycles requested before the panel appears
    private var openToken = 0        // guards against stale async captures
    private(set) var isActive = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() {
        guard !isActive else { return }
        isActive = true
        installEventTap()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        teardown()
        removeEventTap()
    }

    // MARK: Event tap (⌘Tab interception)

    private func installEventTap() {
        let mask = (UInt64(1) << CGEventType.keyDown.rawValue)
                 | (UInt64(1) << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<SwitcherController>.fromOpaque(refcon).takeUnretainedValue()
            return controller.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            DebugLog.log("[MacUtil] switcher: event tap creation FAILED (grant Accessibility / Input Monitoring)")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLog.log("[MacUtil] switcher: ⌘Tab event tap installed")
    }

    private func removeEventTap() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    /// Runs on the main thread (the tap's run-loop source is on the main loop).
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let command = flags.contains(.maskCommand)

        switch type {
        case .flagsChanged:
            if !command {
                if visible { commit() }
                else if opening { commitDuringOpening() }
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
            let shift = flags.contains(.maskShift)

            if command && keyCode == KeyCode.tab {
                let forward = !shift
                if visible { advance(forward: forward) }
                else if opening { pendingSteps += forward ? 1 : -1 }
                else { requestOpen(forward: forward) }
                return nil // swallow — the macOS app switcher never sees it
            }

            if visible {
                switch keyCode {
                case KeyCode.escape: cancel(); return nil
                case KeyCode.left: advance(forward: false); return nil
                case KeyCode.right: advance(forward: true); return nil
                case KeyCode.w where command && !shift: closeSelectedWindow(); return nil
                case KeyCode.q where command && !shift: quitSelectedApp(); return nil
                default: break
                }
            } else if opening, keyCode == KeyCode.escape {
                cancel()
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: Open / cycle

    /// First ⌘Tab: enumerate now (fast), capture thumbnails async, then show the
    /// panel already populated.
    private func requestOpen(forward: Bool) {
        let list = WindowEnumerator.list()
        guard !list.isEmpty else { return }
        windows = list
        pendingSteps = forward ? 1 : -1
        opening = true
        openToken &+= 1
        let token = openToken
        let ids = list.filter { !$0.isMinimized }.map(\.id)

        // Fast path: capture from the cached shareable-window list (skips the
        // SCShareableContent enumeration). Fall back to a live fetch if the cache
        // is missing any current window (e.g. one opened since the last refresh).
        let cached = ThumbnailCapturer.cachedTargets(for: ids)
        let cacheHit = cached.count == ids.count

        Task { [cacheHit, cached, ids, token] in
            let thumbnails = cacheHit
                ? await ThumbnailCapturer.capture(cached)
                : await ThumbnailCapturer.captureLive(ids: ids)
            await MainActor.run { [weak self] in
                guard let self, self.opening, self.openToken == token else { return }
                self.finishOpen(thumbnails: thumbnails)
            }
        }

        // Keep the window-list cache warm for next time (background, off the open path).
        if cacheHit { ThumbnailCapturer.refresh() }
    }

    private func finishOpen(thumbnails: [CGWindowID: NSImage]) {
        opening = false
        self.thumbnails = thumbnails
        let count = windows.count
        guard count > 0 else { teardown(); return }
        selection = ((pendingSteps % count) + count) % count
        visible = true
        showPanel()
        panel.select(index: selection)
        DebugLog.log("[MacUtil] switcher: shown \(count) windows, \(thumbnails.count) previews, sel=\(selection)")
    }

    /// Cycle while the panel is already visible.
    private func advance(forward: Bool) {
        guard visible, !windows.isEmpty else { return }
        selection = forward
            ? (selection + 1) % windows.count
            : (selection - 1 + windows.count) % windows.count
        panel.select(index: selection)
    }

    private func select(index: Int) {
        guard visible, windows.indices.contains(index), selection != index else { return }
        selection = index
        panel.select(index: selection)
    }

    // MARK: Commit / cancel

    private func commit() {
        guard visible else { return }
        let target = windows.indices.contains(selection) ? windows[selection] : nil
        teardown()
        if let target { focus(target) }
    }

    private func commit(index: Int) {
        guard visible, windows.indices.contains(index) else { return }
        selection = index
        commit()
    }

    /// ⌘ released before previews finished — switch immediately, skip the panel.
    private func commitDuringOpening() {
        guard opening, !windows.isEmpty else { teardown(); return }
        let count = windows.count
        let target = windows[((pendingSteps % count) + count) % count]
        teardown()
        focus(target)
    }

    private func cancel() {
        teardown()
    }

    private func teardown() {
        if visible { panel.hide() }
        visible = false
        opening = false
        pendingSteps = 0
        windows = []
        thumbnails = [:]
        selection = 0
    }

    // MARK: Switcher commands

    private func closeSelectedWindow() {
        guard
            visible,
            windows.indices.contains(selection)
        else { return }

        let target = windows[selection]
        guard let axWindow = axWindow(matching: target) else {
            DebugLog.log("[MacUtil] switcher: close failed, AX window not found for \(target.appName):\(target.title)")
            return
        }

        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &value) == .success,
            let value,
            AXUIElementPerformAction(value as! AXUIElement, kAXPressAction as CFString) == .success
        else {
            DebugLog.log("[MacUtil] switcher: close failed, no pressable close button for \(target.appName):\(target.title)")
            return
        }

        removeWindows { $0.id == target.id }
        DebugLog.log("[MacUtil] switcher: closed window \(target.appName):\(target.title)")
    }

    private func quitSelectedApp() {
        guard
            visible,
            windows.indices.contains(selection)
        else { return }

        let target = windows[selection]
        guard let app = NSRunningApplication(processIdentifier: target.pid) else { return }
        if app.terminate() {
            removeWindows { $0.pid == target.pid }
            DebugLog.log("[MacUtil] switcher: quit app \(target.appName)")
        } else {
            DebugLog.log("[MacUtil] switcher: quit failed for \(target.appName)")
        }
    }

    private func removeWindows(where shouldRemove: (SwitchWindow) -> Bool) {
        windows.removeAll(where: shouldRemove)
        if windows.isEmpty {
            teardown()
            return
        }

        selection = min(selection, windows.count - 1)
        thumbnails = thumbnails.filter { id, _ in
            windows.contains { $0.id == id }
        }
        showPanel()
        panel.select(index: selection)
    }

    private func showPanel() {
        panel.show(
            windows: windows,
            thumbnails: thumbnails,
            on: targetScreen(),
            onHover: { [weak self] index in
                self?.select(index: index)
            },
            onClick: { [weak self] index in
                self?.commit(index: index)
            }
        )
    }

    // MARK: Focusing the chosen window

    private func focus(_ target: SwitchWindow) {
        if let axWindow = axWindow(matching: target) {
            if target.isMinimized {
                AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        }
        NSRunningApplication(processIdentifier: target.pid)?.activate()
    }

    private func axWindow(matching target: SwitchWindow) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(target.pid)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
            let axWindows = value as? [AXUIElement]
        else { return nil }

        for axWindow in axWindows {
            var windowID: CGWindowID = 0
            if _AXUIElementGetWindow(axWindow, &windowID) == .success, windowID == target.id {
                return axWindow
            }
        }
        return nil
    }

    // MARK: Helpers

    private func targetScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return Geometry.screen(containing: mouse) ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
