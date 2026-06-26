import AppKit
import CoreServices
import Darwin
import Foundation

/// Mirrors native macOS screenshots to the clipboard while preserving the
/// floating thumbnail flow.
final class ScreenshotClipboardController {
    private enum Constants {
        static let recentFileWindow: TimeInterval = 5 * 60
        static let initialScanDelay: TimeInterval = 0.2
        static let selectionCopyDelay: TimeInterval = 0.04
        static let windowCopyDelay: TimeInterval = 0.08
        static let retryDelay: TimeInterval = 0.8
        static let maxRetries = 5
    }

    private enum PasteboardTypes {
        static let png = NSPasteboard.PasteboardType("public.png")
        static let jpeg = NSPasteboard.PasteboardType("public.jpeg")
        static let tiff = NSPasteboard.PasteboardType("public.tiff")
        static let gif = NSPasteboard.PasteboardType("com.compuserve.gif")
        static let pdf = NSPasteboard.PasteboardType("com.adobe.pdf")
        static let heic = NSPasteboard.PasteboardType("public.heic")
        static let bmp = NSPasteboard.PasteboardType("com.microsoft.bmp")
    }

    private struct Candidate {
        let url: URL
        let key: String
        let date: Date
    }

    private struct ImageSignature: Equatable {
        let width: Int
        let height: Int
    }

    private struct ImmediateCapture {
        let copiedAt: Date
        let pasteboardChangeCount: Int
        let imageSignature: ImageSignature?
        var deleteWhenSaved = false
    }

    private enum CaptureMode {
        case selection
        case window
    }

    private struct InteractiveCapture {
        var mode: CaptureMode = .selection
        var dragStart: CGPoint?
        var latestMouse: CGPoint?
    }

    private static let syntheticEventMarker: Int64 = 0x4d555343
    private static let screencapturePath = "/usr/sbin/screencapture"
    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .creationDateKey,
        .contentModificationDateKey,
        .fileSizeKey,
        .fileResourceIdentifierKey,
    ]

    private var directorySource: DispatchSourceFileSystemObject?
    private var shortcutEventTap: CFMachPort?
    private var shortcutRunLoopSource: CFRunLoopSource?
    private var pendingScan: DispatchWorkItem?
    private var processedKeys = Set<String>()
    private var retryCounts: [String: Int] = [:]
    private var interactiveCapture: InteractiveCapture?
    private var immediateCaptures: [ImmediateCapture] = []
    private var startedAt = Date.distantPast
    private var watchedDirectory: URL?
    private(set) var isActive = false

    func start() {
        guard !isActive else { return }
        isActive = true
        startedAt = Date()
        processedKeys.removeAll()
        retryCounts.removeAll()
        immediateCaptures.removeAll()
        installShortcutEventTap()
        installWatcher()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        pendingScan?.cancel()
        pendingScan = nil
        removeShortcutEventTap()
        directorySource?.cancel()
        directorySource = nil
        interactiveCapture = nil
        immediateCaptures.removeAll()
        watchedDirectory = nil
    }

    // MARK: Screenshot shortcuts

    private func installShortcutEventTap() {
        let mask = (UInt64(1) << CGEventType.keyDown.rawValue)
            | (UInt64(1) << CGEventType.leftMouseDown.rawValue)
            | (UInt64(1) << CGEventType.leftMouseDragged.rawValue)
            | (UInt64(1) << CGEventType.leftMouseUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<ScreenshotClipboardController>
                .fromOpaque(refcon)
                .takeUnretainedValue()
            return controller.handleShortcutEvent(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            DebugLog.log("[MacUtil] screenshots: shortcut event tap creation FAILED (grant Accessibility / Input Monitoring)")
            return
        }

        shortcutEventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        shortcutRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLog.log("[MacUtil] screenshots: shortcut event tap installed")
    }

    private func removeShortcutEventTap() {
        if let shortcutEventTap {
            CGEvent.tapEnable(tap: shortcutEventTap, enable: false)
        }
        if let shortcutRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), shortcutRunLoopSource, .commonModes)
        }
        shortcutRunLoopSource = nil
        shortcutEventTap = nil
    }

    private func handleShortcutEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let shortcutEventTap { CGEvent.tapEnable(tap: shortcutEventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticEventMarker else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .keyDown:
            return handleKeyDown(event)
        case .leftMouseDown:
            beginSelectionDrag(event.location)
        case .leftMouseDragged:
            interactiveCapture?.latestMouse = event.location
        case .leftMouseUp:
            finishInteractiveCapture(event.location)
        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return Unmanaged.passUnretained(event)
        }

        if keyCode == KeyCode.escape {
            interactiveCapture = nil
            return Unmanaged.passUnretained(event)
        }

        if Self.isPasteShortcut(keyCode: keyCode, flags: event.flags) {
            markCurrentScreenshotForDeletionAfterPaste()
            return Unmanaged.passUnretained(event)
        }

        if keyCode == KeyCode.space, var capture = interactiveCapture, capture.dragStart == nil {
            capture.mode = .window
            interactiveCapture = capture
            return Unmanaged.passUnretained(event)
        }

        if Self.isPrintScreenShortcut(keyCode: keyCode, flags: event.flags) {
            copyFullScreenThenReplay(keyCode: keyCode, flags: event.flags)
            return nil
        }

        guard Self.isNativeScreenshotShortcut(keyCode: keyCode, flags: event.flags) else {
            return Unmanaged.passUnretained(event)
        }

        if keyCode == KeyCode.three {
            copyFullScreenThenReplay(keyCode: keyCode, flags: event.flags)
            return nil
        }

        if keyCode == KeyCode.four {
            interactiveCapture = InteractiveCapture()
        }

        return Unmanaged.passUnretained(event)
    }

    private func beginSelectionDrag(_ point: CGPoint) {
        guard var capture = interactiveCapture else { return }
        capture.dragStart = point
        capture.latestMouse = point
        interactiveCapture = capture
    }

    private func finishInteractiveCapture(_ point: CGPoint) {
        guard let capture = interactiveCapture else { return }
        interactiveCapture = nil

        switch capture.mode {
        case .selection:
            guard let start = capture.dragStart else { return }
            let rect = Self.captureRectangle(from: start, to: point)
            guard rect.width >= 2, rect.height >= 2 else { return }
            copySelectionToClipboard(rect, after: Constants.selectionCopyDelay)
        case .window:
            guard let windowID = Self.windowID(at: point) else { return }
            copyWindowToClipboard(windowID, after: Constants.windowCopyDelay)
        }
    }

    private static func isNativeScreenshotShortcut(keyCode: UInt32, flags: CGEventFlags) -> Bool {
        let isScreenshotKey = keyCode == KeyCode.three || keyCode == KeyCode.four
        return isScreenshotKey
            && flags.contains(.maskCommand)
            && flags.contains(.maskShift)
            && !flags.contains(.maskControl)
            && !flags.contains(.maskAlternate)
    }

    private static func isPrintScreenShortcut(keyCode: UInt32, flags: CGEventFlags) -> Bool {
        keyCode == KeyCode.f13
            && !flags.contains(.maskCommand)
            && !flags.contains(.maskShift)
            && !flags.contains(.maskControl)
            && !flags.contains(.maskAlternate)
    }

    private static func isPasteShortcut(keyCode: UInt32, flags: CGEventFlags) -> Bool {
        keyCode == KeyCode.v
            && flags.contains(.maskCommand)
            && !flags.contains(.maskShift)
            && !flags.contains(.maskControl)
            && !flags.contains(.maskAlternate)
    }

    private func copyFullScreenThenReplay(keyCode: UInt32, flags: CGEventFlags) {
        runScreencapture(arguments: ["-c", "-x"]) { [weak self] didCopy in
            if didCopy {
                self?.recordImmediateCapture()
            }
            self?.replayKeyShortcut(keyCode: keyCode, flags: flags)
        }
    }

    private func copySelectionToClipboard(_ rect: CGRect, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.runScreencapture(arguments: [
                "-c",
                "-x",
                "-R",
                Self.rectangleArgument(rect),
            ]) { didCopy in
                if didCopy {
                    self?.recordImmediateCapture()
                }
            }
        }
    }

    private func copyWindowToClipboard(_ windowID: CGWindowID, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.runScreencapture(arguments: [
                "-c",
                "-x",
                "-l",
                "\(windowID)",
            ]) { didCopy in
                if didCopy {
                    self?.recordImmediateCapture()
                }
            }
        }
    }

    private func replayKeyShortcut(keyCode: UInt32, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let replayFlags = Self.replayFlags(from: flags)

        let down = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(keyCode),
            keyDown: true
        )
        down?.flags = replayFlags
        down?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(keyCode),
            keyDown: false
        )
        up?.flags = replayFlags
        up?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        up?.post(tap: .cghidEventTap)
    }

    private static func replayFlags(from flags: CGEventFlags) -> CGEventFlags {
        var replayFlags: CGEventFlags = []
        if flags.contains(.maskCommand) { replayFlags.insert(.maskCommand) }
        if flags.contains(.maskShift) { replayFlags.insert(.maskShift) }
        if flags.contains(.maskControl) { replayFlags.insert(.maskControl) }
        if flags.contains(.maskAlternate) { replayFlags.insert(.maskAlternate) }
        return replayFlags
    }

    private func runScreencapture(arguments: [String], completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            var didCopy = false
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.screencapturePath)
            process.arguments = arguments

            do {
                try process.run()
                process.waitUntilExit()
                didCopy = process.terminationStatus == 0
                if !didCopy {
                    DebugLog.log("[MacUtil] screenshots: screencapture failed status=\(process.terminationStatus) args=\(arguments.joined(separator: " "))")
                }
            } catch {
                DebugLog.log("[MacUtil] screenshots: screencapture failed: \(error.localizedDescription)")
            }

            if let completion {
                DispatchQueue.main.async {
                    completion(didCopy)
                }
            }
        }
    }

    private func recordImmediateCapture() {
        let now = Date()
        let pasteboard = NSPasteboard.general
        immediateCaptures.append(ImmediateCapture(
            copiedAt: now,
            pasteboardChangeCount: pasteboard.changeCount,
            imageSignature: Self.imageSignature(from: pasteboard)
        ))
        trimImmediateCaptures(now: now)
    }

    private func markCurrentScreenshotForDeletionAfterPaste() {
        let now = Date()
        trimImmediateCaptures(now: now)

        guard let index = immediateCaptures.lastIndex(where: { capture in
            guard NSPasteboard.general.changeCount == capture.pasteboardChangeCount else { return false }
            guard let currentSignature = Self.imageSignature(from: NSPasteboard.general),
                  let captureSignature = capture.imageSignature else {
                return capture.imageSignature == nil
            }
            return currentSignature == captureSignature
        }) else {
            return
        }

        immediateCaptures[index].deleteWhenSaved = true
        DebugLog.log("[MacUtil] screenshots: pasted before native save; pending file will be deleted")
    }

    private static func captureRectangle(from start: CGPoint, to end: CGPoint) -> CGRect {
        let minX = min(start.x, end.x)
        let minY = min(start.y, end.y)
        let maxX = max(start.x, end.x)
        let maxY = max(start.y, end.y)
        return CGRect(
            x: floor(minX),
            y: floor(minY),
            width: ceil(maxX - minX),
            height: ceil(maxY - minY)
        )
    }

    private static func rectangleArgument(_ rect: CGRect) -> String {
        "\(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.width)),\(Int(rect.height))"
    }

    private static func windowID(at point: CGPoint) -> CGWindowID? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for window in windows {
            guard let windowID = window[kCGWindowNumber as String] as? CGWindowID,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.contains(point) else {
                continue
            }

            return windowID
        }

        return nil
    }

    // MARK: Directory watching

    private func installWatcher() {
        let directory = Self.screenshotDirectoryURL()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            DebugLog.log("[MacUtil] screenshots: destination does not exist: \(directory.path)")
            return
        }

        let descriptor = Darwin.open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            DebugLog.log("[MacUtil] screenshots: could not watch \(directory.path): errno=\(errno)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleScan(after: Constants.initialScanDelay)
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }

        watchedDirectory = directory
        directorySource = source
        source.resume()
        DebugLog.log("[MacUtil] screenshots: watching \(directory.path)")
    }

    private func scheduleScan(after delay: TimeInterval) {
        guard isActive else { return }
        pendingScan?.cancel()

        let work = DispatchWorkItem { [weak self] in
            self?.scanForScreenshots()
        }
        pendingScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scanForScreenshots() {
        guard isActive, let watchedDirectory else { return }

        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: watchedDirectory,
                includingPropertiesForKeys: Array(Self.resourceKeys),
                options: [.skipsHiddenFiles]
            )
        } catch {
            DebugLog.log("[MacUtil] screenshots: scan failed: \(error.localizedDescription)")
            return
        }

        let now = Date()
        let candidates = urls.compactMap { candidate(for: $0, now: now) }
            .sorted { $0.date < $1.date }

        for candidate in candidates {
            if handleImmediateCaptureSave(candidate) {
                continue
            }
            copyToClipboard(candidate)
        }

        trimProcessedKeysIfNeeded()
        trimImmediateCaptures(now: now)
    }

    private func candidate(for url: URL, now: Date) -> Candidate? {
        guard Self.isSupportedImage(url) else { return nil }

        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: Self.resourceKeys)
        } catch {
            return nil
        }

        guard values.isRegularFile == true,
              let date = [values.creationDate, values.contentModificationDate].compactMap({ $0 }).max(),
              date >= startedAt,
              now.timeIntervalSince(date) <= Constants.recentFileWindow,
              Self.isMacOSScreenshot(url) else {
            return nil
        }

        let key = Self.fileKey(for: url, values: values)
        guard !processedKeys.contains(key) else { return nil }
        return Candidate(url: url, key: key, date: date)
    }

    private func handleImmediateCaptureSave(_ candidate: Candidate) -> Bool {
        guard let index = matchingImmediateCaptureIndex(for: candidate) else { return false }
        let capture = immediateCaptures[index]
        processedKeys.insert(candidate.key)

        if capture.deleteWhenSaved {
            deleteSavedScreenshot(candidate)
        } else {
            DebugLog.log("[MacUtil] screenshots: ignored native save after immediate copy: \(candidate.url.lastPathComponent)")
        }

        return true
    }

    private func matchingImmediateCaptureIndex(for candidate: Candidate) -> Int? {
        let fileSignature = Self.imageSignature(forFileAt: candidate.url)
        return immediateCaptures.lastIndex { capture in
            candidate.date >= capture.copiedAt.addingTimeInterval(-1)
                && candidate.date <= capture.copiedAt.addingTimeInterval(Constants.recentFileWindow)
                && Self.signaturesMatch(capture.imageSignature, fileSignature)
        }
    }

    private static func signaturesMatch(_ lhs: ImageSignature?, _ rhs: ImageSignature?) -> Bool {
        guard let lhs, let rhs else { return true }
        return lhs == rhs
    }

    private func deleteSavedScreenshot(_ candidate: Candidate) {
        do {
            try FileManager.default.removeItem(at: candidate.url)
            DebugLog.log("[MacUtil] screenshots: deleted pasted screenshot file: \(candidate.url.lastPathComponent)")
        } catch {
            DebugLog.log("[MacUtil] screenshots: delete failed for \(candidate.url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: Pasteboard

    private func copyToClipboard(_ candidate: Candidate) {
        guard let item = Self.pasteboardItem(for: candidate.url) else {
            retry(candidate)
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.writeObjects([item]) {
            processedKeys.insert(candidate.key)
            retryCounts[candidate.key] = nil
            DebugLog.log("[MacUtil] screenshots: copied \(candidate.url.lastPathComponent) to clipboard")
        } else {
            retry(candidate)
        }
    }

    private func retry(_ candidate: Candidate) {
        let count = retryCounts[candidate.key, default: 0]
        guard count < Constants.maxRetries else {
            processedKeys.insert(candidate.key)
            retryCounts[candidate.key] = nil
            DebugLog.log("[MacUtil] screenshots: gave up copying \(candidate.url.lastPathComponent)")
            return
        }

        retryCounts[candidate.key] = count + 1
        scheduleScan(after: Constants.retryDelay)
    }

    private static func pasteboardItem(for url: URL) -> NSPasteboardItem? {
        guard let data = try? Data(contentsOf: url),
              let image = NSImage(data: data) else {
            return nil
        }

        let item = NSPasteboardItem()
        if let originalType = pasteboardType(for: url) {
            item.setData(data, forType: originalType)
        }

        if let tiffData = image.tiffRepresentation {
            item.setData(tiffData, forType: PasteboardTypes.tiff)
        }

        return item.types.isEmpty ? nil : item
    }

    private static func imageSignature(from pasteboard: NSPasteboard) -> ImageSignature? {
        for type in [PasteboardTypes.png, PasteboardTypes.tiff, PasteboardTypes.jpeg, PasteboardTypes.heic, PasteboardTypes.gif, PasteboardTypes.bmp] {
            guard let data = pasteboard.data(forType: type),
                  let signature = imageSignature(from: data) else {
                continue
            }
            return signature
        }
        return nil
    }

    private static func imageSignature(forFileAt url: URL) -> ImageSignature? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return imageSignature(from: data)
    }

    private static func imageSignature(from data: Data) -> ImageSignature? {
        if let bitmap = NSBitmapImageRep(data: data) {
            return ImageSignature(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        }

        guard let image = NSImage(data: data) else { return nil }
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        return ImageSignature(width: cgImage.width, height: cgImage.height)
    }

    private static func pasteboardType(for url: URL) -> NSPasteboard.PasteboardType? {
        switch url.pathExtension.lowercased() {
        case "png":
            return PasteboardTypes.png
        case "jpg", "jpeg":
            return PasteboardTypes.jpeg
        case "tif", "tiff":
            return PasteboardTypes.tiff
        case "gif":
            return PasteboardTypes.gif
        case "pdf":
            return PasteboardTypes.pdf
        case "heic":
            return PasteboardTypes.heic
        case "bmp":
            return PasteboardTypes.bmp
        default:
            return nil
        }
    }

    // MARK: Screenshot matching

    private static func isSupportedImage(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "tif", "tiff", "gif", "pdf", "heic", "bmp":
            return true
        default:
            return false
        }
    }

    private static func isMacOSScreenshot(_ url: URL) -> Bool {
        hasScreenCaptureMetadata(url) || matchesScreenshotName(url)
    }

    private static func hasScreenCaptureMetadata(_ url: URL) -> Bool {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL),
              let value = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) else {
            return false
        }

        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            let normalized = string.lowercased()
            return normalized == "true" || normalized == "yes" || normalized == "1"
        }
        return false
    }

    private static func matchesScreenshotName(_ url: URL) -> Bool {
        let filename = url.deletingPathExtension().lastPathComponent
        let normalizedFilename = normalize(filename)
        return screenshotNamePrefixes().contains { prefix in
            normalizedFilename.hasPrefix(normalize(prefix))
        }
    }

    private static func screenshotNamePrefixes() -> [String] {
        var prefixes = [
            "Screenshot",
            "Screen Shot",
            "Skärmavbild",
            "Skarmavbild",
        ]

        if let customName = UserDefaults(suiteName: "com.apple.screencapture")?
            .string(forKey: "name")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !customName.isEmpty {
            prefixes.append(customName)
        }

        return prefixes
    }

    private static func normalize(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    // MARK: Paths and bookkeeping

    private static func screenshotDirectoryURL() -> URL {
        if let location = UserDefaults(suiteName: "com.apple.screencapture")?
            .string(forKey: "location")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !location.isEmpty {
            let url = fileURL(fromScreenshotLocation: location)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return url
            }
        }

        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop", isDirectory: true)
    }

    private static func fileURL(fromScreenshotLocation location: String) -> URL {
        if let url = URL(string: location), url.isFileURL {
            return url
        }

        let expanded = NSString(string: location).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }

        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(expanded, isDirectory: true)
    }

    private static func fileKey(for url: URL, values: URLResourceValues) -> String {
        let identity = values.fileResourceIdentifier.map { String(describing: $0) } ?? url.path
        let modified = values.contentModificationDate ?? values.creationDate ?? .distantPast
        let modifiedMilliseconds = Int(modified.timeIntervalSince1970 * 1000)
        return "\(identity)|\(modifiedMilliseconds)|\(values.fileSize ?? 0)"
    }

    private func trimProcessedKeysIfNeeded() {
        if processedKeys.count > 500 {
            processedKeys.removeAll(keepingCapacity: true)
        }
    }

    private func trimImmediateCaptures(now: Date) {
        immediateCaptures.removeAll { now.timeIntervalSince($0.copiedAt) > Constants.recentFileWindow }
    }
}
