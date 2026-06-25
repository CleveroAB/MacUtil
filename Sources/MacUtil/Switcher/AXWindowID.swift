import ApplicationServices
import CoreGraphics

/// Private AX SPI: maps an AX window element to its `CGWindowID`. This is the
/// reliable way (used by alt-tab-macos) to focus the exact window the user
/// picked rather than just the owning app.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(
    _ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>
) -> AXError
