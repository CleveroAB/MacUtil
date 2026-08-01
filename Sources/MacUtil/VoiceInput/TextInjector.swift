import AppKit
import Carbon.HIToolbox

struct TextInsertionTarget {
    let app: NSRunningApplication?
    let focusedElement: AXUIElement?

    static func current() -> TextInsertionTarget {
        let app = NSWorkspace.shared.frontmostApplication
        guard let app else {
            return TextInsertionTarget(app: nil, focusedElement: nil)
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let focusedElement = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success ? (value as! AXUIElement) : nil

        return TextInsertionTarget(app: app, focusedElement: focusedElement)
    }
}

final class TextInjector {
    private static let markerType = NSPasteboard.PasteboardType("se.clevero.macutil.injection.marker")

    /// Insert `text` at the target's caret via a synthetic ⌘V, saving and
    /// restoring the user's pasteboard.
    ///
    /// - Parameters:
    ///   - activateApp: raise the target app before pasting. Voice input needs
    ///     this (the app may be backgrounded); callers pasting into the field
    ///     being edited must not, since activating another app is disruptive.
    ///   - transient: mark the injected item transient/concealed so clipboard
    ///     managers (Alfred, Maccy, Raycast) don't archive an in-place correction.
    func paste(
        _ text: String,
        into target: TextInsertionTarget,
        activateApp: Bool = true,
        transient: Bool = false
    ) -> Bool {
        guard !text.isEmpty else { return false }
        // A synthetic ⌘V is dropped while Secure Event Input is held, so bail
        // rather than clobber the pasteboard for a paste that can't land.
        guard !Permissions.isSecureInputActive else {
            DebugLog.log("[MacUtil] text injector: skipped, secure input active")
            return false
        }

        let pasteboard = NSPasteboard.general
        let previousItems = pasteboard.pasteboardItems?.compactMap(copyPasteboardItem) ?? []
        let marker = "macutil-injection-\(UUID().uuidString)"
        let payload = text

        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
        pasteboard.setString(marker, forType: Self.markerType)
        if transient {
            pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
        DebugLog.log("[MacUtil] text injector: wrote \(payload.count) characters to pasteboard")

        if activateApp {
            target.app?.activate(options: [.activateAllWindows])
        }
        if let focusedElement = target.focusedElement {
            AXUIElementSetAttributeValue(focusedElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }

        // Post the keystrokes off the main thread: postPasteShortcut() sleeps to
        // separate the key events, and blocking the main thread stalls the whole
        // menu-bar agent. CGEvent posting is thread-safe.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.10) {
            self.postPasteShortcut()
            DebugLog.log("[MacUtil] text injector: posted Cmd-V paste shortcut")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard pasteboard.string(forType: Self.markerType) == marker else {
                return
            }
            pasteboard.clearContents()
            if !previousItems.isEmpty {
                pasteboard.writeObjects(previousItems)
            }
        }

        return true
    }

    private func copyPasteboardItem(_ item: NSPasteboardItem) -> NSPasteboardItem? {
        let copy = NSPasteboardItem()
        var copied = false
        for type in item.types {
            if let data = item.data(forType: type) {
                copy.setData(data, forType: type)
                copied = true
            } else if let string = item.string(forType: type) {
                copy.setString(string, forType: type)
                copied = true
            }
        }
        return copied ? copy : nil
    }

    private func postPasteShortcut() {
        let source = CGEventSource(stateID: .hidSystemState)
        let commandKeyCode = CGKeyCode(kVK_Command)
        let vKeyCode = CGKeyCode(kVK_ANSI_V)

        let commandDown = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: true)
        commandDown?.flags = .maskCommand
        commandDown?.post(tap: .cghidEventTap)

        usleep(10_000)

        let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        vDown?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)

        let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        vUp?.flags = .maskCommand
        vUp?.post(tap: .cghidEventTap)

        usleep(100_000)

        let commandUp = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: false)
        commandUp?.post(tap: .cghidEventTap)
    }
}
