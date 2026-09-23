# Contributing

Thanks for helping improve MacUtil.

## Development Setup

Requirements:

- macOS 14 or newer.
- Xcode 26 or newer. The source references macOS 26 SpeechAnalyzer APIs behind
  availability checks, so older SDKs cannot compile those symbols.
- Accessibility, Screen Recording, Microphone, Speech Recognition, and possibly
  Input Monitoring permissions for full manual testing.

Build and relaunch the app after every source or documentation change:

```bash
Scripts/run.sh
```

Useful alternatives:

```bash
Scripts/run.sh debug
Scripts/build-app.sh
swift build
```

## Project Expectations

- Keep the app native, small, and dependency-free unless there is a strong reason
  to change that.
- Prefer direct AppKit-style implementations over broad abstractions.
- Avoid polling and idle timers unless a feature truly needs them.
- Keep UI dense, functional, and menu-bar-app appropriate.
- Be careful with macOS permissions and code signing. TCC permissions are tied to
  the app signature.
- Document any feature that reads user data, observes global input, uses the
  pasteboard, sends network requests, or touches private/undocumented macOS APIs.

## Validation

Before opening a pull request:

1. Run `swift test` (includes a build and geometry, screenshot-matching, cleanup, and Logitech regression tests).
2. Run `Scripts/build-app.sh` or `Scripts/run.sh`.
3. Manually test any affected permission, shortcut, snapping, switcher,
   voice-input, Logitech, launch-at-login, or status-bar behavior.
4. Note any permissions that need to be refreshed after the change.

The snapping geometry tests live in `Tests/MacUtilTests`. Accessibility hit
testing and native mouse gestures still require manual verification:

- Close or drag a desktop notification; no snap preview or window movement.
- Resize each edge/corner of a window up to a screen boundary; no snap.
- Move a window to left/right/top edges and corners; preview and snap on release.
- Drag content or select text to a screen edge; no snap.
- Drag a snapped window away; its previous size returns and it can snap again.
- Repeat on a second display and with an initially unfocused window.

Keep changes focused and include a manual test note in the PR description.

Additional reliability checks:

- Take different screenshots of the same dimensions in quick succession. Only
  an exact, uniquely matched screenshot pasted before saving may move to Trash;
  unrelated or edited images must remain. Confirm Trash recovery is possible.
- Test app cleanup with hidden/minimized/untitled windows and windows on another
  Space, using disposable apps. All must remain open. An app with truly no
  windows may receive a normal quit request.
- With permission unavailable, inspect Feature Status; after granting access,
  return to an app or reopen MacUtil's menu and verify the failed feature retries.
- Connect two mice and verify Logitech mappings affect only the selected device.
  Unsupported side buttons must remain native. Reconnect and refresh a receiver;
  verify gesture, side-button, battery, and DPI controls. Hardware verification
  is required; the automated tests validate protocol routing, not the device.
- Hold Cmd-Tab with many windows and a slow/unresponsive app. Icons should appear
  without waiting for thumbnails; release or Esc must prevent stale panels.
- Move windows between differently sized displays, including negative screen
  coordinates. Test a minimum-size-constrained window: placement failures should
  beep and appear in Feature Status without losing the restore frame.
