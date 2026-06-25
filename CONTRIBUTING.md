# Contributing

Thanks for helping improve MacUtil.

## Development Setup

Requirements:

- macOS 14 or newer.
- Xcode / Swift toolchain with Swift tools 6.0 support.
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

1. Run `swift build`.
2. Run `Scripts/build-app.sh` or `Scripts/run.sh`.
3. Manually test any affected permission, shortcut, snapping, switcher,
   voice-input, Logitech, launch-at-login, or status-bar behavior.
4. Note any permissions that need to be refreshed after the change.

There is currently no automated test suite. Focus changes tightly and include a
clear manual test note in the PR description.
