import AppKit
import Foundation

/// Reads and changes macOS's system-wide sleep-disabled setting. Unlike a
/// normal power assertion, this setting also covers sleep caused by closing a
/// MacBook lid. Changing it requires administrator authorization.
enum SystemSleepControl {
    enum State: Equatable {
        case enabled
        case disabled
        case unavailable
    }

    enum ChangeError: LocalizedError {
        case cancelled
        case commandFailed(String)
        case stateUnavailable
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Administrator authorization was cancelled."
            case .commandFailed(let message):
                return message
            case .stateUnavailable:
                return "MacUtil could not read macOS's system sleep setting."
            case .verificationFailed:
                return "macOS did not apply the requested system sleep setting."
            }
        }
    }

    static var state: State {
        guard let output = pmsetOutput() else { return .unavailable }

        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.first == "SleepDisabled", let value = fields.last else { continue }
            if value == "1" { return .enabled }
            if value == "0" { return .disabled }
        }
        return .unavailable
    }

    static func setEnabled(_ isEnabled: Bool) throws {
        let value = isEnabled ? "1" : "0"
        let source = "do shell script \"/usr/bin/pmset -a disablesleep \(value)\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else {
            throw ChangeError.commandFailed("MacUtil could not prepare the power-setting command.")
        }

        var details: NSDictionary?
        script.executeAndReturnError(&details)
        if let details {
            let number = (details[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            if number == -128 {
                throw ChangeError.cancelled
            }
            let message = details[NSAppleScript.errorMessage] as? String
                ?? "macOS could not change the system sleep setting."
            throw ChangeError.commandFailed(message)
        }

        let expected: State = isEnabled ? .enabled : .disabled
        let actual = state
        guard actual != .unavailable else { throw ChangeError.stateUnavailable }
        guard actual == expected else { throw ChangeError.verificationFailed }
    }

    private static func pmsetOutput() -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
