import AppKit
import ApplicationServices

/// Reads and writes the frontmost window's geometry through the Accessibility API.
///
/// All public frame methods speak **Cocoa coordinates** (bottom-left origin);
/// conversion to the AX top-left space happens internally via `Geometry`.
final class WindowManager {
    static let shared = WindowManager()

    /// Remembers each window's pre-snap frame so "Restore" can undo a tile.
    /// Keyed by the AX element identity (stable per window via CFEqual/CFHash).
    private struct SavedFrame {
        let frame: NSRect
        let pid: pid_t
        let windowID: CGWindowID
    }
    private var restoreFrames: [AXWindowKey: SavedFrame] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var terminationObserver: NSObjectProtocol?
    private(set) var lastError: String?

    private init() {
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            for key in Array(self.restoreFrames.keys) where self.restoreFrames[key]?.pid == app.processIdentifier {
                self.forget(key.element)
            }
        }
    }

    // MARK: Frontmost window

    /// The focused window of the frontmost application, if any.
    func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &value
        )
        guard result == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    /// Hit-test the actual mouse-down target. Never substitute the focused
    /// window: clicks on notifications, menus, or the desktop must not move it.
    func snappableWindow(at point: NSPoint) -> AXUIElement? {
        let axPoint = Geometry.cocoaToAX(NSRect(origin: point, size: .zero)).origin
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(), Float(axPoint.x), Float(axPoint.y), &hit
        ) == .success, let hit else { return nil }

        let window: AXUIElement
        if stringAttribute(hit, kAXRoleAttribute) == kAXWindowRole {
            window = hit
        } else {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(hit, kAXWindowAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            window = value as! AXUIElement
        }

        var pid: pid_t = 0
        var movable = DarwinBoolean(false)
        var resizable = DarwinBoolean(false)
        guard stringAttribute(window, kAXRoleAttribute) == kAXWindowRole,
              stringAttribute(window, kAXSubroleAttribute) == kAXStandardWindowSubrole,
              AXUIElementGetPid(window, &pid) == .success,
              NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular,
              AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &movable) == .success,
              movable.boolValue,
              AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &resizable) == .success,
              resizable.boolValue else { return nil }
        return window
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: Frame access

    /// Current frame of a window in **Cocoa coordinates**.
    func cocoaFrame(of window: AXUIElement) -> NSRect? {
        guard let axRect = axFrame(of: window) else { return nil }
        return Geometry.axToCocoa(axRect)
    }

    /// Move/resize a window using a **Cocoa-coordinate** rect.
    @discardableResult
    func setCocoaFrame(_ rect: NSRect, of window: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(window, 0.2)
        let errors = setAXFrame(Geometry.cocoaToAX(rect), of: window)
        if let actual = cocoaFrame(of: window), Geometry.approximatelyEqual(actual, rect) {
            lastError = nil
            return true
        }
        lastError = errors.isEmpty
            ? "Window did not accept the requested size or position"
            : "Window placement failed (Accessibility error \(errors[0].rawValue))"
        DebugLog.log("[MacUtil] \(lastError!)")
        return false
    }

    // MARK: Restore memory

    /// Stores the window's current frame the first time it is snapped, so a
    /// later "Restore" can return it. No-op if a frame is already remembered.
    func rememberIfNeeded(_ window: AXUIElement, cocoaFrame: NSRect) {
        pruneClosedWindows()
        let key = AXWindowKey(element: window)
        guard restoreFrames[key] == nil else { return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return }
        var windowID: CGWindowID = 0
        _ = _AXUIElementGetWindow(window, &windowID)
        restoreFrames[key] = SavedFrame(frame: cocoaFrame, pid: pid, windowID: windowID)
        observeDestruction(of: window, pid: pid)
    }

    /// Whether a window has a remembered pre-snap frame.
    func hasRestoreFrame(for window: AXUIElement) -> Bool {
        restoreFrames[AXWindowKey(element: window)] != nil
    }

    /// Restores a window to its remembered pre-snap frame, if any.
    func restore(_ window: AXUIElement) {
        guard let frame = restoreFrames[AXWindowKey(element: window)]?.frame else { return }
        let screen = Geometry.screen(containing: frame) ?? NSScreen.main
        let target = screen.map { Geometry.constrained(frame, to: $0.visibleFrame) } ?? frame
        if setCocoaFrame(target, of: window) { forget(window) }
        else { NSSound.beep() }
    }

    /// Restores the remembered pre-snap size while keeping `point` at the same
    /// relative place inside the current frame. This makes drag-away restore feel
    /// anchored under the cursor instead of jumping back to the old position.
    @discardableResult
    func restoreSize(_ window: AXUIElement, keeping point: NSPoint, relativeTo currentFrame: NSRect) -> Bool {
        guard let frame = restoreFrames[AXWindowKey(element: window)]?.frame else { return false }

        let relativeX = normalizedOffset(point.x - currentFrame.minX, in: currentFrame.width)
        let relativeY = normalizedOffset(point.y - currentFrame.minY, in: currentFrame.height)
        let target = NSRect(
            x: point.x - relativeX * frame.width,
            y: point.y - relativeY * frame.height,
            width: frame.width,
            height: frame.height
        )
        guard setCocoaFrame(target, of: window) else { return false }
        forget(window)
        return true
    }

    private func observeDestruction(of window: AXUIElement, pid: pid_t) {
        if observers[pid] == nil {
            var observer: AXObserver?
            let result = AXObserverCreate(pid, { _, window, _, context in
                guard let context else { return }
                Unmanaged<WindowManager>.fromOpaque(context).takeUnretainedValue().forget(window)
            }, &observer)
            guard result == .success, let observer else { return }
            observers[pid] = observer
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        if let observer = observers[pid] {
            AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString,
                                      Unmanaged.passUnretained(self).toOpaque())
        }
    }

    private func forget(_ window: AXUIElement) {
        guard let saved = restoreFrames.removeValue(forKey: AXWindowKey(element: window)) else { return }
        guard let observer = observers[saved.pid] else { return }
        AXObserverRemoveNotification(observer, window, kAXUIElementDestroyedNotification as CFString)
        if !restoreFrames.values.contains(where: { $0.pid == saved.pid }) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            observers[saved.pid] = nil
        }
    }

    /// Also prune on use for apps that do not support destruction notifications.
    private func pruneClosedWindows() {
        guard !restoreFrames.isEmpty,
              let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return }
        let ids = Set(windows.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        for (key, saved) in Array(restoreFrames) {
            if saved.windowID != 0 && !ids.contains(saved.windowID) { forget(key.element) }
        }
    }

    // MARK: AX plumbing

    private func axFrame(of window: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let posValue, let sizeValue,
            CFGetTypeID(posValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func setAXFrame(_ rect: CGRect, of window: AXUIElement) -> [AXError] {
        var errors: [AXError] = []
        var origin = rect.origin
        var size = rect.size

        // Size → position → size: some apps clamp position based on their current
        // size (and vice-versa), so we bracket the move to land reliably.
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            let result = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            if result != .success { errors.append(result) }
        }
        if let posValue = AXValueCreate(.cgPoint, &origin) {
            let result = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
            if result != .success { errors.append(result) }
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            let result = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            if result != .success { errors.append(result) }
        }
        return errors
    }

    private func normalizedOffset(_ value: CGFloat, in length: CGFloat) -> CGFloat {
        guard length > 0 else { return 0.5 }
        return min(max(value / length, 0), 1)
    }
}

/// Hashable wrapper so AX window elements can key a dictionary.
private struct AXWindowKey: Hashable {
    let element: AXUIElement

    static func == (lhs: AXWindowKey, rhs: AXWindowKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}
