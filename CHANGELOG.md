# Changelog

All notable changes to MacUtil will be documented in this file.

The format follows the spirit of Keep a Changelog, and this project uses
semantic versioning once public releases begin.

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
