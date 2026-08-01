import AppKit
import UniformTypeIdentifiers

/// Rewrites plain ⌘V in opted-in apps so copied files land as text paths.
///
/// Chat-style apps (e.g. T3 Code) reject pasted files unless they are images or
/// PDFs. When the frontmost app is opted in and the pasteboard holds copied
/// files that are not all images/PDFs, the pasteboard is swapped to the files'
/// full paths just before the keystroke reaches the app, then restored right
/// after. The user's own ⌘V does the pasting — no synthetic events — and the
/// tap only runs on key events, so idle cost stays at zero.
final class PathPasteController {
    private static let markerType = NSPasteboard.PasteboardType("se.clevero.macutil.pathpaste.marker")
    private static let restoreDelay: TimeInterval = 1.0

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isActive = false

    func start() {
        guard !isActive else { return }
        isActive = true
        installEventTap()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        removeEventTap()
    }

    func isCurrentApplicationEnabled() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return Settings.shared.pathPasteBundleIdentifiers.contains(bundleID)
    }

    func setCurrentApplicationEnabled(_ enabled: Bool) {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        var identifiers = Settings.shared.pathPasteBundleIdentifiers
        if enabled { identifiers.insert(bundleID) } else { identifiers.remove(bundleID) }
        Settings.shared.pathPasteBundleIdentifiers = identifiers
    }

    // MARK: Event tap

    private func installEventTap() {
        let mask = UInt64(1) << CGEventType.keyDown.rawValue

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<PathPasteController>.fromOpaque(refcon).takeUnretainedValue()
            return controller.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            DebugLog.log("[MacUtil] path-paste: event tap creation FAILED (grant Accessibility)")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLog.log("[MacUtil] path-paste: ⌘V event tap installed")
    }

    private func removeEventTap() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    /// Runs on the main thread (the tap's run-loop source is on the main loop).
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        guard type == .keyDown,
              keyCode == KeyCode.v,
              flags.contains(.maskCommand),
              !flags.contains(.maskShift),
              !flags.contains(.maskAlternate),
              !flags.contains(.maskControl)
        else { return Unmanaged.passUnretained(event) }

        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              Settings.shared.pathPasteBundleIdentifiers.contains(bundleID)
        else { return Unmanaged.passUnretained(event) }

        swapPasteboardIfNeeded()
        return Unmanaged.passUnretained(event)
    }

    // MARK: Pasteboard swap

    private func swapPasteboardIfNeeded() {
        let pasteboard = NSPasteboard.general
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else { return }

        // Images and PDFs paste fine as files; only rewrite when the selection
        // contains something the target app would reject.
        guard !urls.allSatisfy(isNativelySupported) else { return }

        let previousItems = pasteboard.pasteboardItems?.compactMap(copyPasteboardItem) ?? []
        let marker = "macutil-pathpaste-\(UUID().uuidString)"
        let payload = urls.map { $0.standardizedFileURL.path }.joined(separator: "\n")

        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
        pasteboard.setString(marker, forType: Self.markerType)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        DebugLog.log("[MacUtil] path-paste: swapped \(urls.count) file(s) for path text")

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay) {
            guard pasteboard.string(forType: Self.markerType) == marker else { return }
            pasteboard.clearContents()
            if !previousItems.isEmpty {
                pasteboard.writeObjects(previousItems)
            }
            DebugLog.log("[MacUtil] path-paste: restored pasteboard")
        }
    }

    private func isNativelySupported(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return false
        }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
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
}
