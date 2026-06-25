import AppKit

/// Windows-style "drag a window to a screen edge to snap it".
///
/// Uses a single global `NSEvent` monitor for left-button drags. The callback
/// fires *only* while the mouse button is down and moving, so idle cost is zero.
/// When the cursor pins against a screen edge/corner, a translucent preview shows
/// where the window will land; releasing there applies the snap.
final class DragSnapMonitor {
    private var monitor: Any?
    private let overlay = SnapPreviewOverlay()
    private var pending: (action: SnapAction, frame: NSRect)?
    private var dragSession: DragSession?
    private(set) var isActive = false

    /// How close (pt) the cursor must be to a screen edge to engage.
    private let edgeBand: CGFloat = 5
    /// How far (pt) along an edge still counts as a corner zone.
    private let cornerBand: CGFloat = 120
    /// Manual movement needed before a snapped window is considered dragged away.
    private let restoreDragThreshold: CGFloat = 10
    /// Moving a window keeps its size stable; resizing should not trigger restore.
    private let restoreSizeTolerance: CGFloat = 2

    func start() {
        guard !isActive else { return }
        isActive = true
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pending = nil
        dragSession = nil
        overlay.hide()
    }

    // MARK: Event handling

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDragged:
            restoreDraggedSnapIfNeeded()

            if let snap = snap(at: NSEvent.mouseLocation) {
                pending = snap
                overlay.show(frame: snap.frame)
            } else {
                pending = nil
                overlay.hide()
            }

        case .leftMouseUp:
            if let snap = pending {
                apply(snap.frame)
            }
            pending = nil
            dragSession = nil
            overlay.hide()

        default:
            break
        }
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

    private func apply(_ frame: NSRect) {
        let manager = WindowManager.shared
        guard
            let window = manager.focusedWindow(),
            let current = manager.cocoaFrame(of: window)
        else { return }
        manager.rememberIfNeeded(window, cocoaFrame: current)
        manager.setCocoaFrame(frame, of: window)
    }

    private func restoreDraggedSnapIfNeeded() {
        let manager = WindowManager.shared
        guard
            let window = manager.focusedWindow(),
            manager.hasRestoreFrame(for: window),
            let current = manager.cocoaFrame(of: window)
        else {
            dragSession = nil
            return
        }

        if let session = dragSession, CFEqual(session.window, window) {
            guard !session.restored else { return }

            let moved = hypot(
                current.origin.x - session.frameAtStart.origin.x,
                current.origin.y - session.frameAtStart.origin.y
            )
            let sizeChanged =
                abs(current.width - session.frameAtStart.width) > restoreSizeTolerance ||
                abs(current.height - session.frameAtStart.height) > restoreSizeTolerance

            if moved >= restoreDragThreshold && !sizeChanged {
                manager.restoreSize(
                    window,
                    keeping: NSEvent.mouseLocation,
                    relativeTo: current
                )
                dragSession = DragSession(window: window, frameAtStart: current, restored: true)
            }
        } else {
            dragSession = DragSession(window: window, frameAtStart: current, restored: false)
        }
    }
}

private struct DragSession {
    let window: AXUIElement
    let frameAtStart: NSRect
    let restored: Bool
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
