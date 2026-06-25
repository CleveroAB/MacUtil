import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings.shared
    private let snapManager = SnapManager()
    private let dragMonitor = DragSnapMonitor()
    private let windowlessAppQuitter = WindowlessAppQuitter()
    private let switcher = SwitcherController()
    private let logitechManager = LogitechManager()
    private let voiceInput = VoiceInputController()
    private var statusBar: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessibility is needed by both subsystems (move / focus windows).
        Permissions.ensureAccessibility()

        // The switcher needs Screen Recording for thumbnails. Refreshing the
        // ScreenCaptureKit window-list cache at launch both primes the permission
        // (registers the app + shows the one-time prompt) and warms the cache so
        // the first ⌘Tab is already fast.
        if settings.switcherEnabled {
            ThumbnailCapturer.refresh()
        }

        if settings.snappingEnabled { snapManager.start() }
        if settings.dragSnapEnabled { dragMonitor.start() }
        if settings.windowlessQuitterEnabled { windowlessAppQuitter.start() }
        if settings.switcherEnabled { switcher.start() }
        if settings.voiceInputEnabled { voiceInput.start() }

        statusBar = StatusBarController(
            snapManager: snapManager,
            dragMonitor: dragMonitor,
            windowlessAppQuitter: windowlessAppQuitter,
            switcher: switcher,
            logitechManager: logitechManager,
            voiceInput: voiceInput
        )
        logitechManager.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        voiceInput.stop()
        logitechManager.stop()
    }
}
