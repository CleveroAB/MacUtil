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
    func paste(_ text: String, into target: TextInsertionTarget) -> Bool {
        guard !text.isEmpty else { return false }

        let pasteboard = NSPasteboard.general
        let previousItems = pasteboard.pasteboardItems?.compactMap(copyPasteboardItem) ?? []
        let marker = "macutil-voice-\(UUID().uuidString)"
        let payload = text

        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
        pasteboard.setString(marker, forType: NSPasteboard.PasteboardType("se.clevero.macutil.voice.marker"))
        DebugLog.log("[MacUtil] voice: wrote \(payload.count) characters to pasteboard")

        target.app?.activate(options: [.activateAllWindows])
        if let focusedElement = target.focusedElement {
            AXUIElementSetAttributeValue(focusedElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            self.postPasteShortcut()
            DebugLog.log("[MacUtil] voice: posted Cmd-V paste shortcut")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard pasteboard.string(forType: NSPasteboard.PasteboardType("se.clevero.macutil.voice.marker")) == marker else {
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
