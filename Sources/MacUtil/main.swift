import AppKit

// Entry point. MacUtil is a menu-bar agent (no Dock icon, no main window).
// `.accessory` activation policy mirrors the LSUIElement Info.plist flag so the
// app also behaves correctly when run unbundled during development.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
AppMenu.install()
app.setActivationPolicy(.accessory)
app.run()
