import Foundation

/// Opt-in debug logger. Some messages include app/window/device names, so public
/// builds keep logging disabled unless explicitly enabled by defaults or env.
enum DebugLog {
    private static let path = "/tmp/macutil-debug.log"
    private static let defaultsKey = "debugLoggingEnabled"

    private static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
            || ProcessInfo.processInfo.environment["MACUTIL_DEBUG"] == "1"
    }

    static func log(_ message: String) {
        guard isEnabled else { return }
        NSLog("%@", message)
        guard let data = (message + "\n").data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path),
           let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
