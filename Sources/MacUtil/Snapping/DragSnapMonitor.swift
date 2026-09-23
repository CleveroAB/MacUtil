import AppKit

/// Windows-style "drag a window to a screen edge to snap it".
///
/// Uses a single global `NSEvent` monitor for left-button gestures, with no polling.
/// Only a real move of the standard window hit on mouse-down can snap.
/// When the cursor pins against a screen edge/corner, a translucent preview shows
/// where the window will land; releasing there applies the snap.
final class DragSnapMonitor {
    private var monitor: Any?
    private let overlay = SnapPreviewOverlay()
    private var pending: (action: SnapAction, frame: NSRect)?
    private var dragSession: DragSession?
    var isActive: Bool { monitor != nil && Permissions.hasAccessibility }

    /// How close (pt) the cursor must be to a screen edge to engage.
    private let edgeBand: CGFloat = 5
    /// How far (pt) along an edge still counts as a corner zone.
    private let cornerBand: CGFloat = 120
    /// Manual movement needed before a snapped window is considered dragged away.
    private let restoreDragThreshold: CGFloat = 10

    func start() {
        guard !isActive else { return }
        stop()
        guard Permissions.hasAccessibility else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pending = nil
        dragSession = nil
        overlay.hide()
    }

    // MARK: Event handling

    private func handle(_ event: NSEvent) {
        let location = event.cgEvent.map {
            Geometry.axToCocoa(CGRect(origin: $0.location, size: .zero)).origin
        } ?? NSEvent.mouseLocation

        switch event.type {
        case .leftMouseDown:
            resetGesture()
            let manager = WindowManager.shared
            if let window = manager.snappableWindow(at: location),
               let frame = manager.cocoaFrame(of: window) {
                dragSession = DragSession(window: window, motion: WindowDragMotion(frameAtStart: frame))
            }

        case .leftMouseDragged:
            guard updateDragSession(keeping: location) else {
                pending = nil
                overlay.hide()
                return
            }

            if let snap = snap(at: location) {
                pending = snap
                overlay.show(frame: snap.frame)
            } else {
                pending = nil
                overlay.hide()
            }

        case .leftMouseUp:
            // Recheck geometry and the release point: a final resize or a move
            // away from the edge must not commit an earlier preview.
            if pending != nil,
               let session = dragSession,
               let current = WindowManager.shared.cocoaFrame(of: session.window) {
                var motion = session.motion
                if motion.observe(current), let snap = snap(at: location) {
                    apply(snap.frame, to: session.window, current: current)
                }
            }
            resetGesture()

        default:
            break
        }
    }

    private func resetGesture() {
        pending = nil
        dragSession = nil
        overlay.hide()
    }

    /// Determines the snap target for a cursor location, if it is in an edge zone.
    private func snap(at location: NSPoint) -> (action: SnapAction, frame: NSRect)? {
        guard let screen = Geometry.screen(containing: location) else { return nil }
        let f = screen.frame

        let atLeft = location.x <= f.minX + edgeBand
        let atRight = location.x >= f.maxX - edgeBand
        let atTop = location.y >= f.maxY - edgeBand    // Cocoa space: top = high y

        let action: SnapAction?
        if atTop && !atLeft && !atRight {
            action = .maximize
        } else if atLeft {
            if location.y >= f.maxY - cornerBand { action = .topLeft }
            else if location.y <= f.minY + cornerBand { action = .bottomLeft }
            else { action = .leftHalf }
        } else if atRight {
            if location.y >= f.maxY - cornerBand { action = .topRight }
            else if location.y <= f.minY + cornerBand { action = .bottomRight }
            else { action = .rightHalf }
        } else {
            action = nil
        }

        guard
            let action,
            let frame = action.targetFrame(visibleFrame: screen.visibleFrame, current: .zero)
        else { return nil }
        return (action, frame)
    }

    private func apply(_ frame: NSRect, to window: AXUIElement, current: NSRect) {
        let manager = WindowManager.shared
        manager.rememberIfNeeded(window, cocoaFrame: current)
        if !manager.setCocoaFrame(frame, of: window) { NSSound.beep() }
    }

    private func updateDragSession(keeping location: NSPoint) -> Bool {
        let manager = WindowManager.shared
        guard
            var session = dragSession,
            let current = manager.cocoaFrame(of: session.window)
        else {
            dragSession = nil
            return false
        }

        let isMoving = session.motion.observe(current)
        if isMoving,
           session.motion.distanceMoved(current) >= restoreDragThreshold,
           manager.hasRestoreFrame(for: session.window) {
            guard manager.restoreSize(session.window, keeping: location, relativeTo: current),
                  let restored = manager.cocoaFrame(of: session.window) else {
                dragSession = nil
                return false
            }
            // Our own drag-away restore is not a user resize.
            session.motion.acceptRestoredFrame(restored)
        }
        dragSession = session
        return isMoving
    }
}

private struct DragSession {
    let window: AXUIElement
    var motion: WindowDragMotion
}

/// Geometry evidence for one mouse-down/up gesture. Resizing disqualifies the
/// entire gesture, even if the user returns to the original size before release.
struct WindowDragMotion {
    private let frameAtStart: NSRect
    private var expectedSize: NSSize
    private var isMoving = false
    private var isResizing = false

    init(frameAtStart: NSRect) {
        self.frameAtStart = frameAtStart
        expectedSize = frameAtStart.size
    }

    mutating func observe(_ frame: NSRect) -> Bool {
        if abs(frame.width - expectedSize.width) > 1 || abs(frame.height - expectedSize.height) > 1 {
            isResizing = true
        }
        if distanceMoved(frame) >= 5 { isMoving = true }
        return isMoving && !isResizing
    }

    func distanceMoved(_ frame: NSRect) -> CGFloat {
        hypot(frame.minX - frameAtStart.minX, frame.minY - frameAtStart.minY)
    }

    mutating func acceptRestoredFrame(_ frame: NSRect) {
        expectedSize = frame.size
    }
}

/// A reusable, click-through, translucent window used to preview a snap target.
/// Created lazily and shown/hidden — never recreated.
private final class SnapPreviewOverlay {
    private lazy var window: NSWindow = makeWindow()
    private var visible = false

    func show(frame: NSRect) {
        window.setFrame(frame, display: true)
        if !visible {
            window.orderFrontRegardless()
            visible = true
        }
    }

    func hide() {
        guard visible else { return }
        window.orderOut(nil)
        visible = false
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 10
        view.layer?.masksToBounds = true
        window.contentView = view
        return window
    }
}
