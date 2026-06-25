import AppKit

/// Registers the default keymap (see `SnapShortcuts`) and applies the matching
/// `SnapAction` to the frontmost window. Enable/disable via `start()` / `stop()`.
final class SnapManager {
    private var hotKeyIDs: [UInt32] = []
    private(set) var isActive = false

    func start() {
        guard !isActive else { return }
        isActive = true
        for shortcut in SnapShortcuts.all {
            let combo = KeyCombo(keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers)
            if let id = HotKeyCenter.shared.register(combo, handler: { [weak self] in
                self?.apply(shortcut.action)
            }) {
                hotKeyIDs.append(id)
            }
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        hotKeyIDs.forEach { HotKeyCenter.shared.unregister($0) }
        hotKeyIDs.removeAll()
    }

    /// Applies a snap action to the frontmost window. Public so drag-to-edge can
    /// reuse the exact same placement logic.
    func apply(_ action: SnapAction) {
        let manager = WindowManager.shared
        guard
            let window = manager.focusedWindow(),
            let currentFrame = manager.cocoaFrame(of: window)
        else { return }

        let screen = Geometry.screen(containing: currentFrame) ?? NSScreen.main
        guard let screen else { return }

        switch action {
        case .restore:
            manager.restore(window)

        case .nextDisplay, .previousDisplay:
            moveToAdjacentDisplay(
                window: window,
                currentFrame: currentFrame,
                forward: action == .nextDisplay
            )

        default:
            guard let target = action.targetFrame(
                visibleFrame: screen.visibleFrame, current: currentFrame
            ) else { return }
            manager.rememberIfNeeded(window, cocoaFrame: currentFrame)
            manager.setCocoaFrame(target, of: window)
        }
    }

    // MARK: Multi-display

    private func moveToAdjacentDisplay(window: AXUIElement, currentFrame: NSRect, forward: Bool) {
        let screens = NSScreen.screens
        guard
            screens.count > 1,
            let current = Geometry.screen(containing: currentFrame),
            let index = screens.firstIndex(of: current)
        else { return }

        let count = screens.count
        let targetIndex = forward ? (index + 1) % count : (index - 1 + count) % count
        let target = screens[targetIndex]

        // Preserve the window's relative position/size within the visible area.
        let cvf = current.visibleFrame
        let tvf = target.visibleFrame
        let relX = cvf.width > 0 ? (currentFrame.minX - cvf.minX) / cvf.width : 0
        let relY = cvf.height > 0 ? (currentFrame.minY - cvf.minY) / cvf.height : 0

        let newFrame = NSRect(
            x: tvf.minX + relX * tvf.width,
            y: tvf.minY + relY * tvf.height,
            width: min(currentFrame.width, tvf.width),
            height: min(currentFrame.height, tvf.height)
        )

        WindowManager.shared.rememberIfNeeded(window, cocoaFrame: currentFrame)
        WindowManager.shared.setCocoaFrame(newFrame, of: window)
    }
}
