import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings.shared
    private let snapManager = SnapManager()
    private let dragMonitor = DragSnapMonitor()
    private let windowlessAppQuitter = WindowlessAppQuitter()
    private let switcher = SwitcherController()
    private let screenshotClipboard = ScreenshotClipboardController()
    private let updateChecker = UpdateChecker()
    private let logitechManager = LogitechManager()
    private let voiceInput = VoiceInputController()
    private let pathPaste = PathPasteController()
    private var activationObserver: NSObjectProtocol?
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
        if settings.screenshotClipboardEnabled { screenshotClipboard.start() }
        if settings.voiceInputEnabled { voiceInput.start() }
        if settings.pathPasteEnabled { pathPaste.start() }
        updateChecker.start()

        statusBar = StatusBarController(
            snapManager: snapManager,
            dragMonitor: dragMonitor,
            windowlessAppQuitter: windowlessAppQuitter,
            switcher: switcher,
            screenshotClipboard: screenshotClipboard,
            updateChecker: updateChecker,
            logitechManager: logitechManager,
            voiceInput: voiceInput,
            pathPaste: pathPaste
        )
        logitechManager.start()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.statusBar?.refreshFeatureAvailability() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        snapManager.stop()
        dragMonitor.stop()
        windowlessAppQuitter.stop()
        switcher.stop()
        updateChecker.stop()
        screenshotClipboard.stop()
        voiceInput.stop()
        pathPaste.stop()
        logitechManager.stop()
    }
}
