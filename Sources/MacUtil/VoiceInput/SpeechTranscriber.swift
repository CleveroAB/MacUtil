import AVFoundation
import CoreMedia
import Speech

final class SpeechTranscriber: NSObject {
    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var analyzerTask: Task<Void, Never>?
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var inputRouteLease: AudioInputRouteLease?
    private var completion: ((Result<String, VoiceInputError>) -> Void)?
    private var latestTranscript = ""
    private var finished = false
    private var fallbackToken = 0

    var isRecording: Bool {
        recorder?.isRecording == true
    }

    func start(
        onDeviceOnly: Bool,
        completion: @escaping (Result<String, VoiceInputError>) -> Void
    ) throws {
        guard recorder?.isRecording != true else { throw VoiceInputError.alreadyRecording }

        cleanup(cancelTask: true, deleteRecording: true)

        let recognizer: SFSpeechRecognizer?
        if #available(macOS 26.0, *) {
            recognizer = nil
        } else {
            let legacyRecognizer = SFSpeechRecognizer(locale: Locale.autoupdatingCurrent)
                ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
            guard let legacyRecognizer, legacyRecognizer.isAvailable else {
                throw VoiceInputError.speechRecognizerUnavailable
            }
            if onDeviceOnly && !legacyRecognizer.supportsOnDeviceRecognition {
                throw VoiceInputError.onDeviceRecognitionUnavailable
            }
            recognizer = legacyRecognizer
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macutil-voice-\(UUID().uuidString)")
            .appendingPathExtension("caf")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let inputRouteLease = AudioInputRouteManager.shared.temporaryNonBluetoothInputLease()

        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = false
            recorder.prepareToRecord()
            guard recorder.record() else {
                inputRouteLease?.restore()
                throw VoiceInputError.noInput
            }
        } catch {
            inputRouteLease?.restore()
            throw error
        }

        self.recognizer = recognizer
        self.recorder = recorder
        self.inputRouteLease = inputRouteLease
        recordingURL = url
        latestTranscript = ""
        finished = false
        fallbackToken &+= 1
        self.completion = completion
    }

    func stop() {
        guard let recorder else {
            finish(.failure(.noSpeech))
            return
        }

        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        restoreAudioInputRoute()
        if let size = recordedFileSize(at: url) {
            DebugLog.log("[MacUtil] voice: recorded \(size) bytes")
        }

        if #available(macOS 26.0, *) {
            analyzerTask = Task { [weak self] in
                await self?.transcribeRecordingWithSpeechAnalyzer(at: url)
            }
        } else {
            transcribeRecordingWithLegacySpeech(at: url)
        }
    }

    func cancel() {
        DispatchQueue.main.async {
            self.fallbackToken &+= 1
            self.cleanup(cancelTask: true, deleteRecording: true)
        }
    }

    @available(macOS 26.0, *)
    private func transcribeRecordingWithSpeechAnalyzer(at url: URL) async {
        do {
            guard Speech.SpeechTranscriber.isAvailable else {
                throw VoiceInputError.speechRecognizerUnavailable
            }

            let locale = await speechAnalyzerLocale()
            let transcriber = Speech.SpeechTranscriber(locale: locale, preset: .transcription)
            try await ensureSpeechAnalyzerAssets(for: transcriber)
            DebugLog.log("[MacUtil] voice: SpeechAnalyzer locale \(locale.identifier)")

            async let transcription = collectSpeechAnalyzerResults(from: transcriber)

            let analyzer = SpeechAnalyzer(
                modules: [transcriber],
                options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
            )
            let file = try AVAudioFile(forReading: url)

            if let lastSample = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }

            let text = try await transcription
            DebugLog.log("[MacUtil] voice: SpeechAnalyzer produced \(text.count) characters")
            await MainActor.run {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.finish(.failure(.noSpeech))
                } else {
                    self.finish(.success(text))
                }
            }
        } catch let error as VoiceInputError {
            await MainActor.run { self.finish(.failure(error)) }
        } catch {
            await MainActor.run { self.finish(.failure(.underlying(error.localizedDescription))) }
        }
    }

    @available(macOS 26.0, *)
    private func speechAnalyzerLocale() async -> Locale {
        if let locale = await Speech.SpeechTranscriber.supportedLocale(equivalentTo: Locale.autoupdatingCurrent) {
            return locale
        }
        if let locale = await Speech.SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) {
            return locale
        }
        return Locale(identifier: "en-US")
    }

    @available(macOS 26.0, *)
    private func ensureSpeechAnalyzerAssets(for transcriber: Speech.SpeechTranscriber) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        if status == .installed {
            return
        }
        if status == .unsupported {
            throw VoiceInputError.speechRecognizerUnavailable
        }

        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return
        }
        let locales = transcriber.selectedLocales.map(\.identifier).joined(separator: ", ")
        DebugLog.log("[MacUtil] voice: downloading SpeechAnalyzer model for \(locales)")
        try await request.downloadAndInstall()
    }

    @available(macOS 26.0, *)
    private func collectSpeechAnalyzerResults(from transcriber: Speech.SpeechTranscriber) async throws -> String {
        var output = ""
        for try await result in transcriber.results {
            if result.isFinal {
                output += String(result.text.characters)
            }
        }
        return output
    }

    private func transcribeRecordingWithLegacySpeech(at url: URL) {
        guard let recognizer else {
            finish(.failure(.speechRecognizerUnavailable))
            return
        }

        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        if (attributes[.size] as? NSNumber)?.intValue == 0 {
            finish(.failure(.noSpeech))
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = Settings.shared.voiceInputOnDeviceOnly

        fallbackToken &+= 1
        let token = fallbackToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 20.0) { [weak self] in
            guard let self, self.fallbackToken == token else { return }
            self.finishWithBestAvailable()
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handleRecognition(result: result, error: error)
        }
    }

    private func recordedFileSize(at url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        DispatchQueue.main.async {
            if let transcript = result?.bestTranscription.formattedString {
                self.latestTranscript = transcript
            }

            if result?.isFinal == true {
                self.finishWithBestAvailable()
                return
            }

            if let error {
                if !self.latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.finishWithBestAvailable()
                } else {
                    self.finish(.failure(.underlying(error.localizedDescription)))
                }
            }
        }
    }

    private func finishWithBestAvailable() {
        let text = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            finish(.failure(.noSpeech))
        } else {
            finish(.success(text))
        }
    }

    private func finish(_ result: Result<String, VoiceInputError>) {
        guard !finished else { return }
        finished = true
        fallbackToken &+= 1
        cleanup(cancelTask: false, deleteRecording: true)
        let completion = completion
        self.completion = nil
        completion?(result)
    }

    private func cleanup(cancelTask: Bool, deleteRecording: Bool) {
        if recorder?.isRecording == true {
            recorder?.stop()
        }
        recorder = nil
        restoreAudioInputRoute()

        if cancelTask {
            recognitionTask?.cancel()
            analyzerTask?.cancel()
        }
        recognitionTask = nil
        analyzerTask = nil
        recognizer = nil

        if deleteRecording, let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
    }

    private func restoreAudioInputRoute() {
        inputRouteLease?.restore()
        inputRouteLease = nil
    }
}
