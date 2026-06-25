import Foundation

enum VoiceInputError: LocalizedError {
    case alreadyRecording
    case microphoneDenied
    case speechRecognitionDenied
    case speechRecognizerUnavailable
    case onDeviceRecognitionUnavailable
    case noInput
    case noSpeech
    case pasteFailed
    case openRouterAPIKeyMissing
    case aiReplyFailed(String)
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Voice-to-text is already recording."
        case .microphoneDenied:
            return "Microphone access is required for voice-to-text."
        case .speechRecognitionDenied:
            return "Speech Recognition access is required for voice-to-text."
        case .speechRecognizerUnavailable:
            return "Speech recognition is not available for the current language."
        case .onDeviceRecognitionUnavailable:
            return "On-device speech recognition is not available for the current language."
        case .noInput:
            return "No microphone input is available."
        case .noSpeech:
            return "No speech was detected."
        case .pasteFailed:
            return "The transcription could not be pasted into the target app."
        case .openRouterAPIKeyMissing:
            return "OpenRouter API key is required for AI email replies."
        case .aiReplyFailed(let message):
            return "AI email reply failed: \(message)"
        case .underlying(let message):
            return message
        }
    }
}
