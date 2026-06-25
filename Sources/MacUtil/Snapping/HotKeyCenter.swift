import AppKit
import Carbon.HIToolbox

/// A global hotkey: a virtual key code plus a Carbon modifier mask.
struct KeyCombo {
    let keyCode: UInt32
    let modifiers: UInt32
}

/// Carbon modifier masks (combine with `|`).
enum Modifier {
    static let control = UInt32(controlKey)
    static let option = UInt32(optionKey)
    static let command = UInt32(cmdKey)
    static let shift = UInt32(shiftKey)
}

/// Virtual key codes used by MacUtil.
enum KeyCode {
    static let space = UInt32(kVK_Space)
    static let tab = UInt32(kVK_Tab)
    static let escape = UInt32(kVK_Escape)
    static let returnKey = UInt32(kVK_Return)
    static let delete = UInt32(kVK_Delete)
    static let left = UInt32(kVK_LeftArrow)
    static let right = UInt32(kVK_RightArrow)
    static let up = UInt32(kVK_UpArrow)
    static let down = UInt32(kVK_DownArrow)
    static let u = UInt32(kVK_ANSI_U)
    static let i = UInt32(kVK_ANSI_I)
    static let j = UInt32(kVK_ANSI_J)
    static let k = UInt32(kVK_ANSI_K)
    static let q = UInt32(kVK_ANSI_Q)
    static let w = UInt32(kVK_ANSI_W)
    static let c = UInt32(kVK_ANSI_C)
    static let d = UInt32(kVK_ANSI_D)
    static let f = UInt32(kVK_ANSI_F)
    static let g = UInt32(kVK_ANSI_G)
    static let e = UInt32(kVK_ANSI_E)
    static let t = UInt32(kVK_ANSI_T)
}

/// Registers system-wide hotkeys via Carbon `RegisterEventHotKey`.
///
/// This is the lowest-overhead path for global shortcuts (the same mechanism
/// Rectangle uses): it is purely event-driven, so it costs nothing at idle, and
/// registering a combo consumes it so it does not leak to the focused app.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    private init() {}

    /// Registers a hotkey. Returns an opaque id used to `unregister`, or `nil`
    /// if the combo could not be registered (e.g. already claimed system-wide).
    @discardableResult
    func register(_ combo: KeyCombo, handler: @escaping () -> Void) -> UInt32? {
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D555431) /* 'MUT1' */, id: id)

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode, combo.modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else { return nil }

        handlers[id] = handler
        refs[id] = ref
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs[id] {
            UnregisterEventHotKey(ref)
        }
        refs[id] = nil
        handlers[id] = nil
    }

    // MARK: Carbon event handler

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                center.handlers[hotKeyID.id]?()
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
    }
}
