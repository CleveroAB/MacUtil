import AppKit
import ApplicationServices
import CoreGraphics

/// A switchable user-facing window.
struct SwitchWindow {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let bounds: CGRect   // CoreGraphics (top-left) coordinates
    let icon: NSImage?
    let isMinimized: Bool
}

/// Enumerates real, user-facing windows via CoreGraphics plus minimized AX windows.
/// Lightweight (metadata only) — thumbnails are captured separately and lazily.
enum WindowEnumerator {

    /// Front-to-back ordered list of switchable windows, with minimized windows
    /// appended after the visible windows.
    static func list() -> [SwitchWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            DebugLog.log("[MacUtil] enumerate: CGWindowListCopyWindowInfo returned nil")
            return []
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        // When Screen Recording is granted, CGWindow titles are readable; an empty
        // title then means a phantom/utility window with nothing to show (e.g. an
        // app running with no open document) — so we can safely drop those.
        let titlesReadable = CGPreflightScreenCaptureAccess()
        var iconCache: [pid_t: NSImage?] = [:]
        var windows: [SwitchWindow] = []
        var dropped: [String] = []

        for info in raw {
            guard
                let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let id = info[kCGWindowNumber as String] as? CGWindowID,
                let pidValue = info[kCGWindowOwnerPID as String] as? Int
            else { continue }

            let pid = pid_t(pidValue)
            if pid == selfPID { continue }

            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }

            guard
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                bounds.width >= 80, bounds.height >= 80
            else { continue }

            let appName = info[kCGWindowOwnerName as String] as? String ?? ""
            let rawTitle = info[kCGWindowName as String] as? String ?? ""

            if titlesReadable && rawTitle.isEmpty {
                dropped.append("\(appName)[\(Int(bounds.width))x\(Int(bounds.height))]")
                continue
            }

            let title = rawTitle.isEmpty ? appName : rawTitle
            let icon: NSImage?
            if let cached = iconCache[pid] {
                icon = cached
            } else {
                let resolved = NSRunningApplication(processIdentifier: pid)?.icon
                iconCache[pid] = resolved
                icon = resolved
            }

            windows.append(
                SwitchWindow(
                    id: id,
                    pid: pid,
                    appName: appName,
                    title: title,
                    bounds: bounds,
                    icon: icon,
                    isMinimized: false
                )
            )
        }

        let visibleIDs = Set(windows.map(\.id))
        let minimized = minimizedWindows(
            excluding: visibleIDs,
            selfPID: selfPID,
            iconCache: &iconCache
        )
        windows.append(contentsOf: minimized)

        DebugLog.log("[MacUtil] enumerate: kept=\(windows.count) minimized=\(minimized.count) titlesReadable=\(titlesReadable) dropped=[\(dropped.joined(separator: ", "))] list=[\(windows.map { "\($0.appName):\($0.title)\($0.isMinimized ? " [min]" : "")" }.joined(separator: " | "))]")
        return windows
    }

    private static func minimizedWindows(
        excluding existingIDs: Set<CGWindowID>,
        selfPID: pid_t,
        iconCache: inout [pid_t: NSImage?]
    ) -> [SwitchWindow] {
        var windows: [SwitchWindow] = []
        var seenIDs = existingIDs

        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid != selfPID, app.activationPolicy == .regular else { continue }

            let appElement = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
                let axWindows = value as? [AXUIElement]
            else { continue }

            for axWindow in axWindows {
                guard isMinimized(axWindow), isUserWindow(axWindow) else { continue }

                var windowID: CGWindowID = 0
                guard
                    _AXUIElementGetWindow(axWindow, &windowID) == .success,
                    windowID != 0,
                    !seenIDs.contains(windowID)
                else { continue }

                let appName = app.localizedName ?? ""
                let rawTitle = stringAttribute(axWindow, kAXTitleAttribute as CFString) ?? ""
                let title = rawTitle.isEmpty ? appName : rawTitle
                guard !title.isEmpty else { continue }

                let icon: NSImage?
                if let cached = iconCache[pid] {
                    icon = cached
                } else {
                    let resolved = app.icon
                    iconCache[pid] = resolved
                    icon = resolved
                }

                windows.append(
                    SwitchWindow(
                        id: windowID,
                        pid: pid,
                        appName: appName,
                        title: title,
                        bounds: axBounds(of: axWindow) ?? .zero,
                        icon: icon,
                        isMinimized: true
                    )
                )
                seenIDs.insert(windowID)
            }
        }

        return windows
    }

    private static func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success else {
            return false
        }
        return (value as? Bool) == true
    }

    private static func isUserWindow(_ window: AXUIElement) -> Bool {
        guard stringAttribute(window, kAXRoleAttribute as CFString) == (kAXWindowRole as String) else {
            return false
        }

        guard let subrole = stringAttribute(window, kAXSubroleAttribute as CFString) else {
            return true
        }

        return subrole == (kAXStandardWindowSubrole as String)
            || subrole == (kAXDialogSubrole as String)
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private static func axBounds(of window: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let posValue,
            let sizeValue
        else { return nil }

        guard
            CFGetTypeID(posValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(posValue as! AXValue, .cgPoint, &position),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }

        return CGRect(origin: position, size: size)
    }
}
