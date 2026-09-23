# Changelog

All notable changes to MacUtil will be documented in this file.

The format follows the spirit of Keep a Changelog, and this project uses
semantic versioning once public releases begin.

## [0.1.6] - 2026-09-23

### Added

- Feature Status menu showing operational errors, shortcut conflicts, and
  degraded features, plus an Input Monitoring permission link.
- Regression tests for screenshot matching, app-cleanup eligibility,
  cross-display placement, and Logitech report attribution.

### Fixed

- Screenshot cleanup requires a unique exact pixel match and native metadata,
  consumes each match once, and moves files to Trash instead of deleting them.
- App cleanup protects all open windows, including hidden, minimized, untitled,
  and other-Space windows; uncertain inspections never trigger a quit.
- Failed input hooks retry on app activation and menu open.
- Logitech side buttons are handled per physical device/receiver slot, with
  capability-aware controls and event-driven device discovery.
- The switcher preserves untitled windows, bounds preview waiting, limits
  concurrent captures, and moves minimized-window inspection off the input path.
- Cross-display placement constrains the full frame; placement errors are
  reported, failed restores retain their saved frame, and closed-window state
  is cleaned up.
- Drag snapping now follows the standard app window clicked at the start of a
  gesture, ignoring notification, desktop, and stationary-window content drags.
- Resizing a window cancels drag snapping for the entire gesture, including when
  a resize reaches a screen edge or returns to the window's original size.

## [0.1.5] - 2026-08-10

### Added

- A ✕ close button in the top-right corner of hovered Cmd-Tab switcher
  previews, closing that window while the switcher stays open.

### Fixed

- A stationary pointer no longer steals the Cmd-Tab switcher selection when the
  panel opens or scrolls under it; hover selection now requires actually moving
  the mouse.

## [0.1.4] - 2026-08-01

### Added

- Paste File Paths: in opted-in apps (T3 Code by default), pressing ⌘V with
  copied files that are not all images/PDFs pastes the files' full paths as text
  and then restores the pasteboard.
- A system-wide "Keep Mac Awake With Lid Closed" menu toggle for uninterrupted
  remote access and long-running agents.

### Changed

- Limited the Cmd-Tab switcher to seven columns, centered incomplete rows, and
  positioned it within the display's visible frame.

### Fixed

- Made paste-based text injection avoid Secure Event Input and perform its
  synthetic keystroke without blocking the app's main thread.

## [0.1.3] - 2026-06-30

### Fixed

- Wrapped the Cmd-Tab switcher into multiple rows so large window sets remain visible.

## [0.1.2] - 2026-06-26

### Changed

- Moved update checks into the final menu section above Quit.
- Combined manual and automatic update checks under one hover submenu.

## [0.1.1] - 2026-06-26

### Added

- Manual "Check for Updates..." menu item backed by GitHub Releases.
- Opt-in automatic update checks that run at most once a day.

## [0.1.0] - 2026-06-26

### Added

- Initial open-source documentation set.
- Window snapping with keyboard shortcuts and drag-to-edge previews.
- Cmd-Tab window switcher with ScreenCaptureKit thumbnails.
- Voice-to-text dictation.
- Optional OpenRouter-powered AI email replies.
- Logitech HID++ device helper UI and side-button behavior.
- Command-Shift-Q cleanup for apps without visible windows.
- Screenshot clipboard mirroring for native macOS screenshot shortcuts.
- Build scripts for signed local app bundles and release DMG packaging.

### Changed

- Debug logging is opt-in to avoid writing window/device details by default.
