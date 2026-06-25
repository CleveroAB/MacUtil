# Security Policy

## Supported Versions

MacUtil is pre-1.0. Security fixes are expected to land on the main development
line unless a release branch is introduced later.

## Reporting A Vulnerability

Please do not file public issues for vulnerabilities, leaked credentials, or
privacy-sensitive reports.

After the GitHub repository is created, prefer GitHub private vulnerability
reporting if it is enabled for the project. If it is not enabled yet, contact the
maintainer privately and include:

- Affected commit or release.
- macOS version and hardware.
- Exact steps to reproduce.
- Impact, including what data or permissions are involved.
- Any suggested fix or mitigation.

## Security-Relevant Behavior

MacUtil intentionally uses high-trust macOS capabilities:

- Accessibility APIs for window movement, focus, and paste injection.
- Global event taps for shortcuts and input interception.
- ScreenCaptureKit for switcher thumbnails.
- Microphone and Speech APIs for voice-to-text.
- Keychain for the optional OpenRouter API key.
- IOKit HID access for supported Logitech devices.

Review [docs/PRIVACY.md](docs/PRIVACY.md) before enabling features that record
audio, read clipboard context, or send AI reply requests.
