import AppKit

final class VoiceInputController {
    enum Mode: Equatable {
        case dictation
        case aiReply
    }

    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case rewriting

        var isActive: Bool {
            self != .idle
        }

        var title: String {
            switch self {
            case .idle: return "Idle"
            case .recording: return "Recording"
            case .transcribing: return "Transcribing"
            case .rewriting: return "Writing Reply"
            }
        }
    }

    private let settings = Settings.shared
    private let transcriber = SpeechTranscriber()
    private let injector = TextInjector()
    private let openRouter = OpenRouterClient()
    private var dictationHotKeyID: UInt32?
    private var aiReplyHotKeyID: UInt32?
    private var target: TextInsertionTarget?
    private var currentMode: Mode?
    private var aiReplyContext: String?
    private var aiReplyTask: URLSessionDataTask?

    private(set) var state: State = .idle
    private(set) var lastError: String?
    var onStateChanged: ((State) -> Void)?

    var isActive: Bool {
        dictationHotKeyID != nil || aiReplyHotKeyID != nil
    }

    var mode: Mode? {
        currentMode
    }

    func start() {
        guard dictationHotKeyID == nil && aiReplyHotKeyID == nil else { return }

        let dictationCombo = KeyCombo(keyCode: KeyCode.space, modifiers: Modifier.option)
        dictationHotKeyID = HotKeyCenter.shared.register(dictationCombo) { [weak self] in
            self?.toggleRecording()
        }
        if dictationHotKeyID == nil {
            lastError = "Voice-to-text hotkey could not be registered."
            DebugLog.log("[MacUtil] voice: failed to register Option-Space")
            notifyStateChanged()
        }

        let aiReplyCombo = KeyCombo(keyCode: KeyCode.space, modifiers: Modifier.option | Modifier.shift)
        aiReplyHotKeyID = HotKeyCenter.shared.register(aiReplyCombo) { [weak self] in
            self?.toggleAIReplyRecording()
        }
        if aiReplyHotKeyID == nil {
            lastError = "AI email reply hotkey could not be registered."
            DebugLog.log("[MacUtil] voice: failed to register Option-Shift-Space")
            notifyStateChanged()
        }
    }

    func stop() {
        if let dictationHotKeyID {
            HotKeyCenter.shared.unregister(dictationHotKeyID)
        }
        if let aiReplyHotKeyID {
            HotKeyCenter.shared.unregister(aiReplyHotKeyID)
        }
        dictationHotKeyID = nil
        aiReplyHotKeyID = nil
        cancel()
    }

    func toggleRecording() {
        toggleRecording(mode: .dictation)
    }

    func toggleAIReplyRecording() {
        guard settings.voiceAIReplyEnabled else { return }
        toggleRecording(mode: .aiReply)
    }

    private func toggleRecording(mode: Mode) {
        switch state {
        case .idle:
            requestPermissionsThenRecord(target: TextInsertionTarget.current(), mode: mode)
        case .recording:
            stopRecordingForTranscription()
        case .transcribing, .rewriting:
            break
        }
    }

    func cancel() {
        guard state.isActive else { return }
        aiReplyTask?.cancel()
        aiReplyTask = nil
        transcriber.cancel()
        target = nil
        currentMode = nil
        aiReplyContext = nil
        setState(.idle)
    }

    private func requestPermissionsThenRecord(target: TextInsertionTarget, mode: Mode) {
        guard state == .idle else { return }
        lastError = nil

        if mode == .aiReply && !OpenRouterAPIKeyStore.shared.hasAPIKey {
            fail(.openRouterAPIKeyMissing)
            return
        }

        Permissions.ensureMicrophone { [weak self] hasMicrophone in
            DispatchQueue.main.async {
                guard let self, self.state == .idle else { return }
                guard hasMicrophone else {
                    self.fail(.microphoneDenied)
                    return
                }

                Permissions.ensureSpeechRecognition { [weak self] hasSpeechRecognition in
                    DispatchQueue.main.async {
                        guard let self, self.state == .idle else { return }
                        guard hasSpeechRecognition else {
                            self.fail(.speechRecognitionDenied)
                            return
                        }
                        self.beginRecording(target: target, mode: mode)
                    }
                }
            }
        }
    }

    private func beginRecording(target: TextInsertionTarget, mode: Mode) {
        self.target = target
        currentMode = mode
        aiReplyContext = mode == .aiReply ? clipboardEmailContext() : nil

        do {
            VoiceFeedbackSound.playStart()
            try transcriber.start(onDeviceOnly: settings.voiceInputOnDeviceOnly) { [weak self] result in
                self?.handleTranscription(result)
            }
            setState(.recording)
            if mode == .aiReply {
                DebugLog.log("[MacUtil] voice: AI reply recording started; context \(aiReplyContext?.count ?? 0) characters")
            } else {
                DebugLog.log("[MacUtil] voice: recording started")
            }
        } catch let error as VoiceInputError {
            self.target = nil
            currentMode = nil
            aiReplyContext = nil
            fail(error)
        } catch {
            self.target = nil
            currentMode = nil
            aiReplyContext = nil
            fail(.underlying(error.localizedDescription))
        }
    }

    private func stopRecordingForTranscription() {
        setState(.transcribing)
        transcriber.stop()
        VoiceFeedbackSound.playStop(after: 0.28)
        DebugLog.log("[MacUtil] voice: recording stopped; transcribing")
    }

    private func handleTranscription(_ result: Result<String, VoiceInputError>) {
        switch result {
        case .success(let text):
            guard let target else {
                fail(.pasteFailed)
                return
            }

            switch currentMode ?? .dictation {
            case .dictation:
                self.target = nil
                currentMode = nil
                aiReplyContext = nil
                paste(text, into: target)

            case .aiReply:
                generateAndPasteAIReply(from: text, into: target)
            }

        case .failure(let error):
            target = nil
            currentMode = nil
            aiReplyContext = nil
            fail(error)
        }
    }

    private func generateAndPasteAIReply(from transcript: String, into target: TextInsertionTarget) {
        guard let apiKey = OpenRouterAPIKeyStore.shared.apiKey else {
            self.target = nil
            currentMode = nil
            aiReplyContext = nil
            fail(.openRouterAPIKeyMissing)
            return
        }

        setState(.rewriting)
        let model = settings.openRouterModel
        let context = aiReplyContext
        DebugLog.log("[MacUtil] voice: generating AI email reply with \(model)")

        aiReplyTask = openRouter.generateEmailReply(
            transcript: transcript,
            context: context,
            model: model,
            apiKey: apiKey
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.aiReplyTask = nil

                switch result {
                case .success(let reply):
                    self.target = nil
                    self.currentMode = nil
                    self.aiReplyContext = nil
                    self.paste(reply, into: target)
                    DebugLog.log("[MacUtil] voice: generated AI email reply \(reply.count) characters")

                case .failure(let error):
                    self.target = nil
                    self.currentMode = nil
                    self.aiReplyContext = nil
                    self.fail(error)
                }
            }
        }
    }

    private func paste(_ text: String, into target: TextInsertionTarget) {
        if injector.paste(text, into: target) {
            lastError = nil
            setState(.idle)
            DebugLog.log("[MacUtil] voice: pasted \(text.count) characters")
        } else {
            fail(.pasteFailed)
        }
    }

    private func clipboardEmailContext() -> String? {
        guard settings.voiceAIUseClipboardContext else { return nil }
        let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard text.count >= 20 else { return nil }
        return String(text.prefix(12_000))
    }

    private func fail(_ error: VoiceInputError) {
        lastError = error.localizedDescription
        DebugLog.log("[MacUtil] voice: \(lastError ?? "unknown error")")
        setState(.idle)
    }

    private func setState(_ newState: State) {
        state = newState
        notifyStateChanged()
    }

    private func notifyStateChanged() {
        onStateChanged?(state)
    }
}
