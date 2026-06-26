# Privacy Notes

This document describes what MacUtil does locally and when data can leave the
machine. It is not a formal privacy policy.

## Telemetry

MacUtil does not include analytics, telemetry, crash reporting SDKs, or
third-party package dependencies.

## Window Management And Switcher

MacUtil uses Accessibility APIs to read, move, resize, focus, close, and raise
windows. The switcher enumerates visible windows and may read app names, window
titles, process identifiers, window bounds, and minimized state.

ScreenCaptureKit thumbnails are captured on demand while the switcher is being
opened. Thumbnails are kept in memory for the current switcher session and are
not written to disk by MacUtil.

## Voice-To-Text

Voice-to-text records audio to a temporary local `.caf` file, transcribes it with
Apple speech APIs, then deletes the temporary file when transcription completes
or is cancelled.

"On-Device Recognition Only" is enabled by default. On older macOS versions this
sets `requiresOnDeviceRecognition` on the Apple Speech request. On macOS 26 and
newer, MacUtil uses SpeechAnalyzer and may download Apple speech assets for the
selected locale.

The transcribed text is pasted into the focused app by temporarily replacing the
general pasteboard, sending Command-V, and then restoring the prior pasteboard
contents when possible.

## AI Email Replies

AI email replies are optional and require the user to enter an OpenRouter API
key. The key is stored in macOS Keychain with service
`se.clevero.macutil.openrouter`.

When AI email reply mode is invoked, MacUtil sends this data to OpenRouter:

- The selected model slug.
- The spoken transcript.
- Optional clipboard text context, if "Use Clipboard Context" is enabled.
- The OpenRouter API key in the `Authorization` header.

Clipboard context is trimmed and capped before sending. Disable "AI Email Reply"
or "Use Clipboard Context" in the Voice-to-Text menu if you do not want this
behavior.

## Update Checks

Manual update checks and opt-in automatic update checks contact the GitHub
Releases API for `CleveroAB/MacUtil`. Automatic checks are disabled by default
and run at most once a day when enabled.

MacUtil sends the current app version in the HTTP `User-Agent` header. GitHub
receives the normal network metadata for the request, such as IP address.

## Logitech Features

MacUtil enumerates connected Logitech HID devices and can store per-device
settings in UserDefaults, including stable device IDs, DPI choices, gesture
actions, and side-button actions.

## Debug Logs

Debug logging is disabled by default. If enabled, MacUtil writes to
`/tmp/macutil-debug.log` and emits via `NSLog`.

Logs can include app names, window titles, Logitech device names, selected model
names, audio byte counts, character counts, and error messages. They should not
include API keys, full transcripts, generated AI replies, screenshots, or audio
data by design.

Enable logging:

```bash
defaults write se.clevero.macutil debugLoggingEnabled -bool true
```

Disable logging and remove the existing file:

```bash
defaults delete se.clevero.macutil debugLoggingEnabled
rm -f /tmp/macutil-debug.log
```

## Settings Storage

MacUtil stores feature toggles and device preferences in UserDefaults under the
app bundle identifier `se.clevero.macutil`. The optional OpenRouter API key is
stored in Keychain, not UserDefaults.
