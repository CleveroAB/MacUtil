# Open-Source Audit

Audit date: 2026-06-25

Scope: local MacUtil working tree before initial GitHub publication.

## Summary

MacUtil is reasonable to publish as a source-built personal macOS utility after
adding public project documentation, ignore rules, and a license. The main
remaining non-code publishing tasks are to initialize Git, choose the GitHub
owner/repository name, confirm the license holder, and decide whether to publish
binary releases.

## Repository State

- No `.git` repository was present during the audit.
- No `LICENSE`, `.gitignore`, `CONTRIBUTING.md`, `SECURITY.md`, or privacy note
  existed before this pass.
- Generated/local artifacts were present and should not be published:
  `.build/`, `build/`, `.DS_Store` files, and `.claude/settings.local.json`.
- The generated SwiftPM/build output accounted for most local disk usage.

## Dependency And Build Surface

- `Package.swift` declares no third-party dependencies.
- Swift tools version is 6.0 with Swift 5 language mode.
- Minimum platform is macOS 14.
- Building currently requires an Xcode 26 SDK because the source references
  macOS 26 SpeechAnalyzer symbols behind availability checks.
- The release app bundle is produced by `Scripts/build-app.sh`, packaged as a
  DMG by `Scripts/package-dmg.sh`, and relaunched locally by `Scripts/run.sh`.
- Build signing prefers Developer ID Application, then Apple Development, then
  ad-hoc signing. Developer ID builds use hardened runtime.

## Secret And Private Data Scan

No hardcoded API keys, bearer tokens, passwords, GitHub tokens, private keys, or
personal absolute paths were found in source, scripts, resources, or docs outside
of the local audit path itself.

Important findings:

- OpenRouter API keys are user-provided and stored in Keychain.
- The OpenRouter endpoint is hardcoded as
  `https://openrouter.ai/api/v1/chat/completions`.
- `.claude/settings.local.json` is local tool state and is now ignored.
- `.DS_Store`, `.build/`, and `build/` are now ignored.

## Privacy And Permission Findings

MacUtil intentionally asks for high-trust macOS permissions:

- Accessibility for window movement/focus, event taps, and paste injection.
- Screen Recording for switcher thumbnails.
- Microphone and Speech Recognition for voice-to-text.
- Input Monitoring may be required for some event-tap and Logitech behavior.

AI email reply mode can send the spoken transcript and optional clipboard context
to OpenRouter. This is documented in `README.md` and `docs/PRIVACY.md`.

Debug logging previously wrote to `/tmp/macutil-debug.log` by default. That was
changed to opt-in because logs can include app names, window titles, device
names, model names, counts, and error messages.

## App Store / Distribution Risk

This project should be presented as a source-built utility, not an App Store
submission target.

Reasons:

- Uses global event taps and hotkeys that require sensitive permissions.
- Uses private AX SPI via `_AXUIElementGetWindow`.
- Uses an undocumented Dock notification symbol via `CoreDockSendNotification`
  for Logitech gesture behavior, with a keyboard fallback.
- Uses Logitech HID++ behavior that may vary by device, receiver, transport, and
  macOS privacy settings.

## Publish Readiness Checklist

Completed in this pass:

- Refreshed README with feature, permission, privacy, signing, and build notes.
- Added `.gitignore`.
- Added MIT `LICENSE`.
- Added `CONTRIBUTING.md`.
- Added `SECURITY.md`.
- Added `CODE_OF_CONDUCT.md`.
- Added `CHANGELOG.md`.
- Added `docs/PRIVACY.md`.
- Added `docs/PUBLISHING.md`.
- Added a GitHub Actions build workflow.
- Made debug logging opt-in.
- Added repeatable signed DMG packaging for GitHub Releases.

Still recommended before public launch:

- Confirm the MIT license and copyright holder.
- Initialize Git and make the first commit.
- Choose the public GitHub repository owner/name.
- Enable GitHub private vulnerability reporting.
- Add screenshots or a short demo GIF if desired.
- Add Apple notarization credentials for fully notarized release artifacts.
- Consider adding automated tests around pure logic if the project grows.
