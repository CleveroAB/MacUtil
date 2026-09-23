import AppKit

/// The menu-bar status item and its menu: feature toggles, launch-at-login,
/// live permission status, and Quit.
final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let snapManager: SnapManager
    private let dragMonitor: DragSnapMonitor
    private let windowlessAppQuitter: WindowlessAppQuitter
    private let switcher: SwitcherController
    private let screenshotClipboard: ScreenshotClipboardController
    private let updateChecker: UpdateChecker
    private let logitechManager: LogitechManager
    private let voiceInput: VoiceInputController
    private let pathPaste: PathPasteController
    private let userGuide = UserGuideWindowController()
    private let settings = Settings.shared
    private var logitechWindows: [String: LogitechDeviceWindowController] = [:]
    private var healthMenu: NSMenu?
    private var isMenuOpen = false
    private var menuNeedsReload = false
    private var voiceAnimationTimer: Timer?
    private var voiceAnimationFrame = 0

    // Items whose state is refreshed each time the menu opens.
    private var snappingItem: NSMenuItem?
    private var snappingEnabledItem: NSMenuItem?
    private var voiceInputItem: NSMenuItem?
    private var voiceInputEnabledItem: NSMenuItem?
    private var voiceInputActionItem: NSMenuItem?
    private var voiceAIReplyActionItem: NSMenuItem?
    private var voiceAIReplyEnabledItem: NSMenuItem?
    private var voiceAIUseClipboardContextItem: NSMenuItem?
    private var voiceAIModelItem: NSMenuItem?
    private var voiceAIKeyItem: NSMenuItem?
    private var voiceInputModeItem: NSMenuItem?
    private var pathPasteItem: NSMenuItem?
    private var pathPasteEnabledItem: NSMenuItem?
    private var pathPasteAppItem: NSMenuItem?
    private var keepAwakeItem: NSMenuItem?
    private var loginItem: NSMenuItem?
    private var automaticUpdatesItem: NSMenuItem?
    private var accessibilityItem: NSMenuItem?
    private var inputMonitoringItem: NSMenuItem?
    private var screenRecordingItem: NSMenuItem?
    private var microphoneItem: NSMenuItem?
    private var speechRecognitionItem: NSMenuItem?

    init(
        snapManager: SnapManager,
        dragMonitor: DragSnapMonitor,
        windowlessAppQuitter: WindowlessAppQuitter,
        switcher: SwitcherController,
        screenshotClipboard: ScreenshotClipboardController,
        updateChecker: UpdateChecker,
        logitechManager: LogitechManager,
        voiceInput: VoiceInputController,
        pathPaste: PathPasteController
    ) {
        self.snapManager = snapManager
        self.dragMonitor = dragMonitor
        self.windowlessAppQuitter = windowlessAppQuitter
        self.switcher = switcher
        self.screenshotClipboard = screenshotClipboard
        self.updateChecker = updateChecker
        self.logitechManager = logitechManager
        self.voiceInput = voiceInput
        self.pathPaste = pathPaste
        super.init()
        configureButton()
        statusItem.menu = buildMenu()
        logitechManager.onDevicesChanged = { [weak self] in
            self?.reloadMenu()
            self?.refreshLogitechWindows()
        }
        voiceInput.onStateChanged = { [weak self] _ in
            DispatchQueue.main.async {
                self?.voiceInputStateChanged()
            }
        }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = NSImage(
            systemSymbolName: "macwindow.on.rectangle",
            accessibilityDescription: "MacUtil"
        )
        button.image?.isTemplate = true
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let windowSnapping = toggle("Window Snapping (keyboard)", #selector(toggleSnapping), settings.snappingEnabled)
        windowSnapping.submenu = snappingShortcutsMenu()
        menu.addItem(windowSnapping)
        snappingItem = windowSnapping
        menu.addItem(toggle("Drag-to-Edge Snapping", #selector(toggleDragSnap), settings.dragSnapEnabled))
        menu.addItem(toggle("Window Switcher", #selector(toggleSwitcher), settings.switcherEnabled, keyEquivalent: "\t", modifiers: [.command]))
        menu.addItem(toggle("Quit Apps Without Windows", #selector(toggleWindowlessQuitter), settings.windowlessQuitterEnabled, keyEquivalent: "q", modifiers: [.command, .shift]))
        menu.addItem(toggle("Copy Screenshots to Clipboard", #selector(toggleScreenshotClipboard), settings.screenshotClipboardEnabled))

        let keepAwake = NSMenuItem(
            title: "Keep Mac Awake With Lid Closed",
            action: #selector(toggleKeepAwake),
            keyEquivalent: ""
        )
        keepAwake.target = self
        menu.addItem(keepAwake)
        keepAwakeItem = keepAwake
        updateKeepAwakeMenuItem()

        let voice = toggle("Voice-to-Text", #selector(toggleVoiceInput), settings.voiceInputEnabled)
        voice.submenu = voiceInputMenu()
        menu.addItem(voice)
        voiceInputItem = voice

        let pathPasteToggle = toggle("Paste File Paths", #selector(togglePathPaste), settings.pathPasteEnabled)
        pathPasteToggle.submenu = pathPasteMenu()
        menu.addItem(pathPasteToggle)
        pathPasteItem = pathPasteToggle

        menu.addItem(.separator())
        addLogitechDevices(to: menu)

        menu.addItem(.separator())
        let health = NSMenuItem(title: "Feature Status", action: nil, keyEquivalent: "")
        healthMenu = NSMenu()
        health.submenu = healthMenu
        menu.addItem(health)
        updateFeatureStatus()
        let guide = NSMenuItem(title: "User Guide", action: #selector(showUserGuide), keyEquivalent: "")
        guide.target = self
        menu.addItem(guide)

        let permissions = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
        let permissionsMenu = NSMenu()

        let accessibility = NSMenuItem(title: "Accessibility", action: #selector(openAccessibility), keyEquivalent: "")
        accessibility.target = self
        permissionsMenu.addItem(accessibility)
        accessibilityItem = accessibility

        let inputMonitoring = NSMenuItem(title: "Input Monitoring", action: #selector(openInputMonitoring), keyEquivalent: "")
        inputMonitoring.target = self
        permissionsMenu.addItem(inputMonitoring)
        inputMonitoringItem = inputMonitoring

        let screenRecording = NSMenuItem(title: "Screen Recording", action: #selector(openScreenRecording), keyEquivalent: "")
        screenRecording.target = self
        permissionsMenu.addItem(screenRecording)
        screenRecordingItem = screenRecording

        let microphone = NSMenuItem(title: "Microphone", action: #selector(openMicrophone), keyEquivalent: "")
        microphone.target = self
        permissionsMenu.addItem(microphone)
        microphoneItem = microphone

        let speechRecognition = NSMenuItem(title: "Speech Recognition", action: #selector(openSpeechRecognition), keyEquivalent: "")
        speechRecognition.target = self
        permissionsMenu.addItem(speechRecognition)
        speechRecognitionItem = speechRecognition

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        permissionsMenu.addItem(login)
        loginItem = login

        permissions.submenu = permissionsMenu
        menu.addItem(permissions)

        menu.addItem(.separator())

        let updates = NSMenuItem(title: "Check for Updates", action: nil, keyEquivalent: "")
        updates.submenu = updatesMenu()
        menu.addItem(updates)

        let quit = NSMenuItem(title: "Quit MacUtil", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    /// Called on app activation and menu open, with no permission polling timer.
    func refreshFeatureAvailability() {
        logitechManager.refreshPermissionState()
        if settings.snappingEnabled { snapManager.start() }
        if settings.dragSnapEnabled { dragMonitor.start() }
        if settings.windowlessQuitterEnabled { windowlessAppQuitter.start() }
        if settings.switcherEnabled { switcher.start() }
        if settings.pathPasteEnabled { pathPaste.start() }
        if settings.screenshotClipboardEnabled { screenshotClipboard.start() }
        updateFeatureStatus()
    }

    private func updateFeatureStatus() {
        func inputIssue(_ active: Bool) -> String? {
            if !Permissions.hasAccessibility { return "Grant Accessibility in Permissions" }
            return active ? nil : "Input hook unavailable; check Accessibility / Input Monitoring"
        }
        let rows: [(String, Bool, String?)] = [
            ("Keyboard snapping", settings.snappingEnabled,
             snapManager.registrationError ?? inputIssue(snapManager.isActive)),
            ("Drag snapping", settings.dragSnapEnabled, inputIssue(dragMonitor.isActive)),
            ("Window switcher", settings.switcherEnabled,
             inputIssue(switcher.isActive) ?? (Permissions.hasScreenRecording ? nil : "Icons only; grant Screen Recording for previews")),
            ("App cleanup", settings.windowlessQuitterEnabled, inputIssue(windowlessAppQuitter.isActive)),
            ("Screenshot clipboard", settings.screenshotClipboardEnabled, screenshotClipboard.statusIssue),
            ("Paste file paths", settings.pathPasteEnabled, inputIssue(pathPaste.isActive)),
            ("Logitech discovery", true, logitechManager.discoveryIssue),
            ("Voice shortcuts", settings.voiceInputEnabled, voiceInput.lastError ?? (voiceInput.isActive ? nil : "Shortcut unavailable")),
        ]
        healthMenu?.removeAllItems()
        for (name, enabled, issue) in rows {
            let description = enabled ? (issue ?? "Ready") : "Off"
            let item = NSMenuItem(title: "\(name): \(description)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.state = enabled ? (issue == nil ? .on : .mixed) : .off
            item.toolTip = description
            healthMenu?.addItem(item)
        }
        if let error = WindowManager.shared.lastError {
            healthMenu?.addItem(.separator())
            let item = NSMenuItem(title: "Last window placement: \(error)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            healthMenu?.addItem(item)
        }
    }

    private func reloadMenu() {
        if isMenuOpen {
            menuNeedsReload = true
            return
        }
        statusItem.menu = buildMenu()
    }

    private func addLogitechDevices(to menu: NSMenu) {
        let header = NSMenuItem(title: "Logitech Devices", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let devices = logitechManager.currentDevices()
        guard !devices.isEmpty else {
            let empty = NSMenuItem(title: "No connected Logitech HID++ devices", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for device in devices {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            let row = LogitechDeviceMenuRow(device: device)
            row.onClick = { [weak self] deviceID in
                self?.statusItem.menu?.cancelTracking()
                self?.showLogitechDevice(deviceID)
            }
            item.view = row
            menu.addItem(item)
        }
    }

    private func toggle(
        _ title: String,
        _ action: Selector,
        _ isOn: Bool,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.state = isOn ? .on : .off
        return item
    }

    /// Lists every snapping action with its shortcut. Built from the same
    /// `SnapShortcuts.all` the hotkeys are registered from, so the displayed
    /// keys always match what actually fires. Clicking an item also applies it
    /// to the current window.
    private func snappingShortcutsMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let enabled = NSMenuItem(title: "Enabled", action: #selector(toggleSnapping), keyEquivalent: "")
        enabled.target = self
        enabled.state = settings.snappingEnabled ? .on : .off
        submenu.addItem(enabled)
        snappingEnabledItem = enabled

        submenu.addItem(.separator())

        var lastGroup: Int?
        for shortcut in SnapShortcuts.all {
            let group = snapGroup(shortcut.action)
            if let last = lastGroup, last != group {
                submenu.addItem(.separator())
            }
            lastGroup = group

            let item = NSMenuItem(
                title: shortcut.name,
                action: #selector(performSnap(_:)),
                keyEquivalent: shortcut.keyEquivalent
            )
            item.keyEquivalentModifierMask = shortcut.displayModifiers
            item.target = self
            item.representedObject = shortcut.action
            submenu.addItem(item)
        }

        return submenu
    }

    private func voiceInputMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let enabled = NSMenuItem(title: "Enabled", action: #selector(toggleVoiceInput), keyEquivalent: "")
        enabled.target = self
        enabled.state = settings.voiceInputEnabled ? .on : .off
        submenu.addItem(enabled)
        voiceInputEnabledItem = enabled

        let action = NSMenuItem(
            title: voiceInputActionTitle(),
            action: #selector(toggleVoiceRecording),
            keyEquivalent: " "
        )
        action.keyEquivalentModifierMask = [.option]
        action.target = self
        action.isEnabled = voiceInputActionEnabled(for: .dictation)
        submenu.addItem(action)
        voiceInputActionItem = action

        let aiReplyAction = NSMenuItem(
            title: voiceAIReplyActionTitle(),
            action: #selector(toggleAIReplyRecording),
            keyEquivalent: " "
        )
        aiReplyAction.keyEquivalentModifierMask = [.option, .shift]
        aiReplyAction.target = self
        aiReplyAction.isEnabled = voiceInputActionEnabled(for: .aiReply)
        submenu.addItem(aiReplyAction)
        voiceAIReplyActionItem = aiReplyAction

        if voiceInput.state.isActive {
            let status = NSMenuItem(title: "Status: \(voiceInput.state.title)", action: nil, keyEquivalent: "")
            status.isEnabled = false
            submenu.addItem(status)
        } else if let error = voiceInput.lastError {
            let status = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            status.isEnabled = false
            submenu.addItem(status)
        }

        submenu.addItem(.separator())

        let onDeviceOnly = NSMenuItem(
            title: "On-Device Recognition Only",
            action: #selector(toggleVoiceOnDeviceOnly),
            keyEquivalent: ""
        )
        onDeviceOnly.target = self
        onDeviceOnly.state = settings.voiceInputOnDeviceOnly ? .on : .off
        submenu.addItem(onDeviceOnly)
        voiceInputModeItem = onDeviceOnly

        submenu.addItem(.separator())

        let aiEnabled = NSMenuItem(title: "AI Email Reply", action: #selector(toggleVoiceAIReply), keyEquivalent: "")
        aiEnabled.target = self
        aiEnabled.state = settings.voiceAIReplyEnabled ? .on : .off
        submenu.addItem(aiEnabled)
        voiceAIReplyEnabledItem = aiEnabled

        let apiKey = NSMenuItem(title: openRouterAPIKeyTitle(), action: #selector(setOpenRouterAPIKey), keyEquivalent: "")
        apiKey.target = self
        submenu.addItem(apiKey)
        voiceAIKeyItem = apiKey

        let model = NSMenuItem(title: openRouterModelTitle(), action: #selector(setOpenRouterModel), keyEquivalent: "")
        model.target = self
        submenu.addItem(model)
        voiceAIModelItem = model

        let clipboardContext = NSMenuItem(
            title: "Use Clipboard as Email Context",
            action: #selector(toggleVoiceAIClipboardContext),
            keyEquivalent: ""
        )
        clipboardContext.target = self
        clipboardContext.state = settings.voiceAIUseClipboardContext ? .on : .off
        submenu.addItem(clipboardContext)
        voiceAIUseClipboardContextItem = clipboardContext

        return submenu
    }

    private func pathPasteMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let enabled = NSMenuItem(title: "Enabled", action: #selector(togglePathPaste), keyEquivalent: "")
        enabled.target = self
        enabled.state = settings.pathPasteEnabled ? .on : .off
        submenu.addItem(enabled)
        pathPasteEnabledItem = enabled

        let info = NSMenuItem(
            title: "Pastes full paths when copied files are not images/PDFs",
            action: nil,
            keyEquivalent: ""
        )
        info.isEnabled = false
        submenu.addItem(info)

        submenu.addItem(.separator())

        let app = NSMenuItem(title: pathPasteAppTitle(), action: #selector(togglePathPasteApp), keyEquivalent: "")
        app.target = self
        app.isEnabled = canTargetCurrentApplication()
        submenu.addItem(app)
        pathPasteAppItem = app

        return submenu
    }

    private func updatesMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let checkNow = NSMenuItem(title: "Check Now...", action: #selector(checkForUpdates), keyEquivalent: "")
        checkNow.target = self
        submenu.addItem(checkNow)

        let automaticUpdates = toggle(
            "Check for Updates Automatically",
            #selector(toggleAutomaticUpdates),
            settings.automaticUpdateChecksEnabled
        )
        submenu.addItem(automaticUpdates)
        automaticUpdatesItem = automaticUpdates

        return submenu
    }

    private func voiceInputActionTitle() -> String {
        switch voiceInput.state {
        case .idle:
            return "Start Recording"
        case .recording:
            if voiceInput.mode == .aiReply { return "AI Reply Recording..." }
            return "Stop and Transcribe"
        case .transcribing:
            return "Transcribing..."
        case .rewriting:
            return "Writing Reply..."
        }
    }

    private func voiceAIReplyActionTitle() -> String {
        switch voiceInput.state {
        case .idle:
            return "Start AI Email Reply"
        case .recording:
            return voiceInput.mode == .aiReply ? "Stop and Write Reply" : "Recording..."
        case .transcribing:
            return voiceInput.mode == .aiReply ? "Transcribing Reply..." : "Transcribing..."
        case .rewriting:
            return "Writing Reply..."
        }
    }

    private func voiceInputActionEnabled(for mode: VoiceInputController.Mode) -> Bool {
        guard settings.voiceInputEnabled else { return false }
        if mode == .aiReply && !settings.voiceAIReplyEnabled { return false }

        switch voiceInput.state {
        case .idle:
            return true
        case .recording:
            return voiceInput.mode == mode
        case .transcribing, .rewriting:
            return false
        }
    }

    private func openRouterAPIKeyTitle() -> String {
        OpenRouterAPIKeyStore.shared.hasAPIKey
            ? "OpenRouter API Key: Set..."
            : "OpenRouter API Key: Not Set..."
    }

    private func openRouterModelTitle() -> String {
        "OpenRouter Model: \(settings.openRouterModel)"
    }

    private func pathPasteAppTitle() -> String {
        guard canTargetCurrentApplication(),
              let appName = NSWorkspace.shared.frontmostApplication?.localizedName else {
            return "Current App Unavailable"
        }
        return pathPaste.isCurrentApplicationEnabled()
            ? "Disable in \(appName)"
            : "Enable in \(appName)"
    }

    private func canTargetCurrentApplication() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        return app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            && app.bundleIdentifier != nil
    }

    private func snapGroup(_ action: SnapAction) -> Int {
        switch action {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf,
             .topLeft, .topRight, .bottomLeft, .bottomRight:
            return 0
        case .maximize, .center, .restore:
            return 1
        case .firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds:
            return 2
        case .nextDisplay, .previousDisplay:
            return 3
        }
    }

    // MARK: Actions

    @objc private func performSnap(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? SnapAction else { return }
        snapManager.apply(action)
    }

    @objc private func toggleSnapping(_ sender: NSMenuItem) {
        settings.snappingEnabled.toggle()
        settings.snappingEnabled ? snapManager.start() : snapManager.stop()
        sender.state = settings.snappingEnabled ? .on : .off
        snappingItem?.state = settings.snappingEnabled ? .on : .off
        snappingEnabledItem?.state = settings.snappingEnabled ? .on : .off
    }

    @objc private func toggleDragSnap(_ sender: NSMenuItem) {
        settings.dragSnapEnabled.toggle()
        settings.dragSnapEnabled ? dragMonitor.start() : dragMonitor.stop()
        sender.state = settings.dragSnapEnabled ? .on : .off
    }

    @objc private func toggleWindowlessQuitter(_ sender: NSMenuItem) {
        settings.windowlessQuitterEnabled.toggle()
        settings.windowlessQuitterEnabled ? windowlessAppQuitter.start() : windowlessAppQuitter.stop()
        sender.state = settings.windowlessQuitterEnabled ? .on : .off
    }

    @objc private func toggleSwitcher(_ sender: NSMenuItem) {
        settings.switcherEnabled.toggle()
        settings.switcherEnabled ? switcher.start() : switcher.stop()
        sender.state = settings.switcherEnabled ? .on : .off
    }

    @objc private func toggleScreenshotClipboard(_ sender: NSMenuItem) {
        settings.screenshotClipboardEnabled.toggle()
        settings.screenshotClipboardEnabled ? screenshotClipboard.start() : screenshotClipboard.stop()
        sender.state = settings.screenshotClipboardEnabled ? .on : .off
    }

    @objc private func toggleKeepAwake() {
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            self?.changeKeepAwakeSetting()
        }
    }

    @objc private func toggleVoiceInput(_ sender: NSMenuItem) {
        settings.voiceInputEnabled.toggle()
        settings.voiceInputEnabled ? voiceInput.start() : voiceInput.stop()
        sender.state = settings.voiceInputEnabled ? .on : .off
        voiceInputItem?.state = sender.state
        voiceInputEnabledItem?.state = sender.state
        updateVoiceInputMenuItems()
    }

    @objc private func toggleVoiceRecording() {
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            self?.voiceInput.toggleRecording()
        }
    }

    @objc private func toggleAIReplyRecording() {
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            self?.voiceInput.toggleAIReplyRecording()
        }
    }

    @objc private func toggleVoiceOnDeviceOnly(_ sender: NSMenuItem) {
        settings.voiceInputOnDeviceOnly.toggle()
        sender.state = settings.voiceInputOnDeviceOnly ? .on : .off
        voiceInputModeItem?.state = sender.state
    }

    @objc private func toggleVoiceAIReply(_ sender: NSMenuItem) {
        settings.voiceAIReplyEnabled.toggle()
        sender.state = settings.voiceAIReplyEnabled ? .on : .off
        voiceAIReplyEnabledItem?.state = sender.state
        updateVoiceInputMenuItems()
    }

    @objc private func toggleVoiceAIClipboardContext(_ sender: NSMenuItem) {
        settings.voiceAIUseClipboardContext.toggle()
        sender.state = settings.voiceAIUseClipboardContext ? .on : .off
        voiceAIUseClipboardContextItem?.state = sender.state
    }

    @objc private func setOpenRouterAPIKey() {
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            self?.showOpenRouterAPIKeyPrompt()
        }
    }

    @objc private func setOpenRouterModel() {
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            self?.showOpenRouterModelPrompt()
        }
    }

    @objc private func togglePathPaste(_ sender: NSMenuItem) {
        settings.pathPasteEnabled.toggle()
        settings.pathPasteEnabled ? pathPaste.start() : pathPaste.stop()
        updatePathPasteMenuItems()
    }

    @objc private func togglePathPasteApp() {
        pathPaste.setCurrentApplicationEnabled(!pathPaste.isCurrentApplicationEnabled())
        updatePathPasteMenuItems()
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        sender.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func showUserGuide() {
        userGuide.showGuide()
    }

    @objc private func checkForUpdates() {
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            self?.updateChecker.checkForUpdates(userInitiated: true)
        }
    }

    @objc private func toggleAutomaticUpdates(_ sender: NSMenuItem) {
        let isEnabled = !settings.automaticUpdateChecksEnabled
        updateChecker.setAutomaticChecksEnabled(isEnabled)
        sender.state = isEnabled ? .on : .off
        automaticUpdatesItem?.state = sender.state
    }

    private func showLogitechDevice(_ deviceID: String) {
        guard let device = logitechManager.device(withID: deviceID) else { return }
        let controller = logitechWindows[deviceID] ?? LogitechDeviceWindowController(
            device: device,
            manager: logitechManager
        )
        logitechWindows[deviceID] = controller
        controller.update(device: device)
        controller.showDevice()
    }

    private func refreshLogitechWindows() {
        var devices: [String: LogitechDeviceSnapshot] = [:]
        for device in logitechManager.currentDevices() {
            devices[device.id] = device
        }
        for (id, controller) in logitechWindows {
            guard let device = devices[id] else { continue }
            controller.update(device: device)
        }
    }

    @objc private func openAccessibility() {
        Permissions.openAccessibilitySettings()
    }

    @objc private func openInputMonitoring() { Permissions.openInputMonitoringSettings() }

    @objc private func openScreenRecording() {
        // Trigger the prompt if it has never been asked; otherwise open Settings.
        if !Permissions.hasScreenRecording {
            Permissions.ensureScreenRecording()
        }
        Permissions.openScreenRecordingSettings()
    }

    @objc private func openMicrophone() {
        Permissions.ensureMicrophone { _ in }
        Permissions.openMicrophoneSettings()
    }

    @objc private func openSpeechRecognition() {
        Permissions.ensureSpeechRecognition { _ in }
        Permissions.openSpeechRecognitionSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func voiceInputStateChanged() {
        updateVoiceInputMenuItems()
        if voiceInput.state.isActive {
            startVoiceAnimation()
        } else {
            stopVoiceAnimation()
        }
    }

    private func updateVoiceInputMenuItems() {
        voiceInputItem?.state = settings.voiceInputEnabled ? .on : .off
        voiceInputEnabledItem?.state = settings.voiceInputEnabled ? .on : .off
        voiceInputActionItem?.title = voiceInputActionTitle()
        voiceInputActionItem?.isEnabled = voiceInputActionEnabled(for: .dictation)
        voiceAIReplyActionItem?.title = voiceAIReplyActionTitle()
        voiceAIReplyActionItem?.isEnabled = voiceInputActionEnabled(for: .aiReply)
        voiceInputModeItem?.state = settings.voiceInputOnDeviceOnly ? .on : .off
        voiceAIReplyEnabledItem?.state = settings.voiceAIReplyEnabled ? .on : .off
        voiceAIUseClipboardContextItem?.state = settings.voiceAIUseClipboardContext ? .on : .off
        voiceAIModelItem?.title = openRouterModelTitle()
        voiceAIKeyItem?.title = openRouterAPIKeyTitle()
    }

    private func updatePathPasteMenuItems() {
        pathPasteItem?.state = settings.pathPasteEnabled ? .on : .off
        pathPasteEnabledItem?.state = settings.pathPasteEnabled ? .on : .off
        pathPasteAppItem?.title = pathPasteAppTitle()
        pathPasteAppItem?.isEnabled = canTargetCurrentApplication()
    }

    private func updateKeepAwakeMenuItem() {
        guard let keepAwakeItem else { return }
        switch SystemSleepControl.state {
        case .enabled:
            keepAwakeItem.title = "Keep Mac Awake With Lid Closed"
            keepAwakeItem.state = .on
            keepAwakeItem.isEnabled = true
            keepAwakeItem.toolTip = "System sleep is disabled until this is turned off."
        case .disabled:
            keepAwakeItem.title = "Keep Mac Awake With Lid Closed"
            keepAwakeItem.state = .off
            keepAwakeItem.isEnabled = true
            keepAwakeItem.toolTip = "Requires administrator approval."
        case .unavailable:
            keepAwakeItem.title = "Keep Mac Awake With Lid Closed (Unavailable)"
            keepAwakeItem.state = .off
            keepAwakeItem.isEnabled = false
            keepAwakeItem.toolTip = "MacUtil could not read the macOS system sleep setting."
        }
    }

    private func changeKeepAwakeSetting() {
        let currentState = SystemSleepControl.state
        guard currentState != .unavailable else {
            showKeepAwakeError("MacUtil could not read the macOS system sleep setting.")
            return
        }

        let shouldEnable = currentState == .disabled
        if shouldEnable && !confirmKeepAwakeEnable() { return }

        do {
            try SystemSleepControl.setEnabled(shouldEnable)
        } catch SystemSleepControl.ChangeError.cancelled {
            return
        } catch {
            showKeepAwakeError(error.localizedDescription)
        }
        updateKeepAwakeMenuItem()
    }

    private func confirmKeepAwakeEnable() -> Bool {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Keep Mac Awake With the Lid Closed?"
        alert.informativeText = "This disables all system sleep so remote sessions and running agents can continue after the lid closes. Keep the Mac connected to power and well ventilated, and never put it in a bag while this is enabled. macOS may still shut down for a low battery or thermal emergency."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Awake")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showKeepAwakeError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Keep Mac Awake"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func startVoiceAnimation() {
        if voiceAnimationTimer == nil {
            let timer = Timer(timeInterval: 0.42, repeats: true) { [weak self] _ in
                self?.advanceVoiceAnimation()
            }
            voiceAnimationTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        advanceVoiceAnimation()
    }

    private func stopVoiceAnimation() {
        voiceAnimationTimer?.invalidate()
        voiceAnimationTimer = nil
        voiceAnimationFrame = 0
        configureButton()
    }

    private func advanceVoiceAnimation() {
        guard let button = statusItem.button else { return }
        let frames: [String]
        switch voiceInput.state {
        case .recording:
            frames = ["mic.circle", "mic.circle.fill"]
        case .transcribing:
            frames = ["waveform.circle", "waveform.circle.fill"]
        case .rewriting:
            frames = ["sparkles", "pencil.circle.fill"]
        case .idle:
            stopVoiceAnimation()
            return
        }

        let symbol = frames[voiceAnimationFrame % frames.count]
        voiceAnimationFrame += 1
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Voice-to-text \(voiceInput.state.title)")
            ?? NSImage(systemSymbolName: "mic.circle", accessibilityDescription: "Voice-to-text")
        button.image?.isTemplate = true
        button.title = ""
    }

    private func showOpenRouterAPIKeyPrompt() {
        promptForText(
            title: "OpenRouter API Key",
            message: "Paste an OpenRouter API key. Leave blank and press OK to clear it.",
            initialValue: "",
            secure: true
        ) { [weak self] value in
            do {
                try OpenRouterAPIKeyStore.shared.setAPIKey(value)
                self?.reloadMenu()
            } catch let error as VoiceInputError {
                self?.voiceInputLastError(error.localizedDescription)
            } catch {
                self?.voiceInputLastError(error.localizedDescription)
            }
        }
    }

    private func showOpenRouterModelPrompt() {
        promptForText(
            title: "OpenRouter Model",
            message: "Enter an OpenRouter model slug, for example ~openai/gpt-latest.",
            initialValue: settings.openRouterModel,
            secure: false
        ) { [weak self] value in
            guard let self else { return }
            self.settings.openRouterModel = value
            self.reloadMenu()
        }
    }

    private func promptForText(
        title: String,
        message: String,
        initialValue: String,
        secure: Bool,
        completion: (String) -> Void
    ) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field: NSTextField = secure ? NSSecureTextField(string: initialValue) : NSTextField(string: initialValue)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        field.lineBreakMode = .byTruncatingMiddle
        field.isEditable = true
        field.isSelectable = true
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            completion(field.stringValue)
        }
    }

    private func voiceInputLastError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Voice-to-Text"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

extension StatusBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        refreshFeatureAvailability()
        loginItem?.state = LoginItem.isEnabled ? .on : .off
        accessibilityItem?.state = Permissions.hasAccessibility ? .on : .off
        inputMonitoringItem?.state = Permissions.hasInputMonitoring ? .on : .off
        screenRecordingItem?.state = Permissions.hasScreenRecording ? .on : .off
        microphoneItem?.state = Permissions.hasMicrophone ? .on : .off
        speechRecognitionItem?.state = Permissions.hasSpeechRecognition ? .on : .off
        automaticUpdatesItem?.state = settings.automaticUpdateChecksEnabled ? .on : .off
        updateKeepAwakeMenuItem()
        updateVoiceInputMenuItems()
        updatePathPasteMenuItems()
        logitechManager.refreshDevices()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        if menuNeedsReload {
            menuNeedsReload = false
            reloadMenu()
        }
    }
}

private final class LogitechDeviceMenuRow: NSControl {
    let deviceID: String
    var onClick: ((String) -> Void)?

    private let nameLabel = NSTextField(labelWithString: "")
    private let batteryLabel = NSTextField(labelWithString: "")
    private var trackingAreaRef: NSTrackingArea?
    private var isHovered = false {
        didSet { updateHighlight() }
    }
    private var isPressed = false {
        didSet { updateHighlight() }
    }

    init(device: LogitechDeviceSnapshot) {
        self.deviceID = device.id
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 24))

        wantsLayer = true
        layer?.cornerRadius = 4

        nameLabel.stringValue = device.name
        nameLabel.font = .menuFont(ofSize: 0)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        batteryLabel.stringValue = device.batteryTitle
        batteryLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        batteryLabel.textColor = .secondaryLabelColor
        batteryLabel.alignment = .right
        batteryLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(nameLabel)
        addSubview(batteryLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            widthAnchor.constraint(equalToConstant: 280),

            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: batteryLabel.leadingAnchor, constant: -12),

            batteryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            batteryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            batteryLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 280, height: 24)
    }

    override func updateTrackingAreas() {
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { isPressed = false }
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?(deviceID)
    }

    private func updateHighlight() {
        let highlighted = isHovered || isPressed
        layer?.backgroundColor = highlighted
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(isPressed ? 0.55 : 0.38).cgColor
            : NSColor.clear.cgColor

        nameLabel.textColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        batteryLabel.textColor = highlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
    }
}
