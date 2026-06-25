import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Speech

/// Thin wrappers around the two TCC permissions MacUtil needs.
///
/// - Accessibility: required to read/move windows (snapping) and to focus a
///   chosen window (switcher).
/// - Screen Recording: required for live thumbnails. The switcher degrades to
///   icon + title if it is denied.
/// - Microphone / Speech Recognition: required for voice-to-text.
enum Permissions {

    // MARK: Accessibility

    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Returns the current trust state and, if untrusted, shows the system prompt.
    @discardableResult
    static func ensureAccessibility() -> Bool {
        // Using the literal key string avoids SDK-version differences in how
        // `kAXTrustedCheckOptionPrompt` is imported (CFString vs Unmanaged).
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    // MARK: Screen Recording

    static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the Screen Recording prompt the first time it is called.
    @discardableResult
    static func ensureScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    // MARK: Microphone

    static var hasMicrophone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func ensureMicrophone(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                completion(granted)
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    // MARK: Speech Recognition

    static var hasSpeechRecognition: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    static func ensureSpeechRecognition(_ completion: @escaping (Bool) -> Void) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            completion(true)
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in
                completion(status == .authorized)
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    static func openSpeechRecognitionSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
    }

    // MARK: Helpers

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
