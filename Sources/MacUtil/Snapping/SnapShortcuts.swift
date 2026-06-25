import AppKit
import Carbon.HIToolbox

/// A single snapping shortcut definition. It carries everything both consumers
/// need so the registered hotkey and the menu display can never drift apart:
/// the Carbon key code + mask for `RegisterEventHotKey`, and the
/// `NSMenuItem`-friendly key equivalent + modifier flags for display.
struct SnapShortcut {
    let action: SnapAction
    let name: String
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let keyEquivalent: String
    let displayModifiers: NSEvent.ModifierFlags
}

/// The default snapping keymap — the one source of truth for both
/// `SnapManager` (hotkey registration) and `StatusBarController` (menu display).
///
/// Base modifier is **Option+Command** (⌥⌘). Display moves add **Control**
/// (⌃⌥⌘) so they don't collide with the half-snap arrows.
enum SnapShortcuts {
    static let all: [SnapShortcut] = {
        let optCmd = Modifier.option | Modifier.command
        let optCmdFlags: NSEvent.ModifierFlags = [.option, .command]
        let ctrlOptCmd = Modifier.control | Modifier.option | Modifier.command
        let ctrlOptCmdFlags: NSEvent.ModifierFlags = [.control, .option, .command]

        // Glyph-rendering key equivalents for the menu.
        func fn(_ code: Int) -> String { String(UnicodeScalar(code)!) }
        let left = fn(NSLeftArrowFunctionKey)
        let right = fn(NSRightArrowFunctionKey)
        let up = fn(NSUpArrowFunctionKey)
        let down = fn(NSDownArrowFunctionKey)
        let ret = "\r"          // ↩
        let del = "\u{8}"       // ⌫ (backspace)

        return [
            // Halves
            SnapShortcut(action: .leftHalf,   name: "Left Half",   keyCode: KeyCode.left,  carbonModifiers: optCmd, keyEquivalent: left,  displayModifiers: optCmdFlags),
            SnapShortcut(action: .rightHalf,  name: "Right Half",  keyCode: KeyCode.right, carbonModifiers: optCmd, keyEquivalent: right, displayModifiers: optCmdFlags),
            SnapShortcut(action: .topHalf,    name: "Top Half",    keyCode: KeyCode.up,    carbonModifiers: optCmd, keyEquivalent: up,    displayModifiers: optCmdFlags),
            SnapShortcut(action: .bottomHalf, name: "Bottom Half", keyCode: KeyCode.down,  carbonModifiers: optCmd, keyEquivalent: down,  displayModifiers: optCmdFlags),
            // Quarters
            SnapShortcut(action: .topLeft,     name: "Top Left",     keyCode: KeyCode.u, carbonModifiers: optCmd, keyEquivalent: "u", displayModifiers: optCmdFlags),
            SnapShortcut(action: .topRight,    name: "Top Right",    keyCode: KeyCode.i, carbonModifiers: optCmd, keyEquivalent: "i", displayModifiers: optCmdFlags),
            SnapShortcut(action: .bottomLeft,  name: "Bottom Left",  keyCode: KeyCode.j, carbonModifiers: optCmd, keyEquivalent: "j", displayModifiers: optCmdFlags),
            SnapShortcut(action: .bottomRight, name: "Bottom Right", keyCode: KeyCode.k, carbonModifiers: optCmd, keyEquivalent: "k", displayModifiers: optCmdFlags),
            // Maximize / center / restore
            SnapShortcut(action: .maximize, name: "Maximize", keyCode: KeyCode.returnKey, carbonModifiers: optCmd, keyEquivalent: ret, displayModifiers: optCmdFlags),
            SnapShortcut(action: .center,   name: "Center",   keyCode: KeyCode.c,         carbonModifiers: optCmd, keyEquivalent: "c", displayModifiers: optCmdFlags),
            SnapShortcut(action: .restore,  name: "Restore",  keyCode: KeyCode.delete,    carbonModifiers: optCmd, keyEquivalent: del, displayModifiers: optCmdFlags),
            // Thirds
            SnapShortcut(action: .firstThird,     name: "First Third",      keyCode: KeyCode.d, carbonModifiers: optCmd, keyEquivalent: "d", displayModifiers: optCmdFlags),
            SnapShortcut(action: .centerThird,    name: "Center Third",     keyCode: KeyCode.f, carbonModifiers: optCmd, keyEquivalent: "f", displayModifiers: optCmdFlags),
            SnapShortcut(action: .lastThird,      name: "Last Third",       keyCode: KeyCode.g, carbonModifiers: optCmd, keyEquivalent: "g", displayModifiers: optCmdFlags),
            SnapShortcut(action: .firstTwoThirds, name: "First Two Thirds", keyCode: KeyCode.e, carbonModifiers: optCmd, keyEquivalent: "e", displayModifiers: optCmdFlags),
            SnapShortcut(action: .lastTwoThirds,  name: "Last Two Thirds",  keyCode: KeyCode.t, carbonModifiers: optCmd, keyEquivalent: "t", displayModifiers: optCmdFlags),
            // Move across displays
            SnapShortcut(action: .previousDisplay, name: "Previous Display", keyCode: KeyCode.left,  carbonModifiers: ctrlOptCmd, keyEquivalent: left,  displayModifiers: ctrlOptCmdFlags),
            SnapShortcut(action: .nextDisplay,     name: "Next Display",     keyCode: KeyCode.right, carbonModifiers: ctrlOptCmd, keyEquivalent: right, displayModifiers: ctrlOptCmdFlags),
        ]
    }()
}
