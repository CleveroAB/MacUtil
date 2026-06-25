import Foundation
import ServiceManagement

/// Launch-at-login via the modern `SMAppService` API (macOS 13+).
/// Requires the app to run from a bundle (i.e. the assembled `.app`).
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("[MacUtil] Login item update failed: \(error.localizedDescription)")
            return false
        }
    }
}
