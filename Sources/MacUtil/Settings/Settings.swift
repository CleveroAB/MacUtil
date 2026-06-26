import Foundation

/// Lightweight UserDefaults-backed store for feature toggles.
/// The shortcut keymap lives in `SnapManager` for v1; this is where a future
/// remapping UI would persist overrides.
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let snapping = "snappingEnabled"
        static let dragSnap = "dragSnapEnabled"
        static let windowlessQuitter = "windowlessQuitterEnabled"
        static let switcher = "switcherEnabled"
        static let screenshotClipboard = "screenshotClipboardEnabled"
        static let voiceInput = "voiceInputEnabled"
        static let voiceInputOnDeviceOnly = "voiceInputOnDeviceOnly"
        static let voiceAIReply = "voiceAIReplyEnabled"
        static let voiceAIUseClipboardContext = "voiceAIUseClipboardContext"
        static let openRouterModel = "openRouterModel"
        static let logitechGestureActions = "logitechGestureActions"
        static let logitechSideButtonActions = "logitechSideButtonActions"
        static let logitechDPIValues = "logitechDPIValues"
    }

    private init() {
        defaults.register(defaults: [
            Key.snapping: true,
            Key.dragSnap: true,
            Key.windowlessQuitter: true,
            Key.switcher: true,
            Key.screenshotClipboard: true,
            Key.voiceInput: true,
            Key.voiceInputOnDeviceOnly: true,
            Key.voiceAIReply: true,
            Key.voiceAIUseClipboardContext: true,
            Key.openRouterModel: "~openai/gpt-latest",
            Key.logitechGestureActions: [:],
            Key.logitechSideButtonActions: [:],
            Key.logitechDPIValues: [:],
        ])
    }

    var snappingEnabled: Bool {
        get { defaults.bool(forKey: Key.snapping) }
        set { defaults.set(newValue, forKey: Key.snapping) }
    }

    var dragSnapEnabled: Bool {
        get { defaults.bool(forKey: Key.dragSnap) }
        set { defaults.set(newValue, forKey: Key.dragSnap) }
    }

    var windowlessQuitterEnabled: Bool {
        get { defaults.bool(forKey: Key.windowlessQuitter) }
        set { defaults.set(newValue, forKey: Key.windowlessQuitter) }
    }

    var switcherEnabled: Bool {
        get { defaults.bool(forKey: Key.switcher) }
        set { defaults.set(newValue, forKey: Key.switcher) }
    }

    var screenshotClipboardEnabled: Bool {
        get { defaults.bool(forKey: Key.screenshotClipboard) }
        set { defaults.set(newValue, forKey: Key.screenshotClipboard) }
    }

    var voiceInputEnabled: Bool {
        get { defaults.bool(forKey: Key.voiceInput) }
        set { defaults.set(newValue, forKey: Key.voiceInput) }
    }

    var voiceInputOnDeviceOnly: Bool {
        get { defaults.bool(forKey: Key.voiceInputOnDeviceOnly) }
        set { defaults.set(newValue, forKey: Key.voiceInputOnDeviceOnly) }
    }

    var voiceAIReplyEnabled: Bool {
        get { defaults.bool(forKey: Key.voiceAIReply) }
        set { defaults.set(newValue, forKey: Key.voiceAIReply) }
    }

    var voiceAIUseClipboardContext: Bool {
        get { defaults.bool(forKey: Key.voiceAIUseClipboardContext) }
        set { defaults.set(newValue, forKey: Key.voiceAIUseClipboardContext) }
    }

    var openRouterModel: String {
        get {
            let value = defaults.string(forKey: Key.openRouterModel)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? "~openai/gpt-latest" : value
        }
        set {
            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(value.isEmpty ? "~openai/gpt-latest" : value, forKey: Key.openRouterModel)
        }
    }

    func logitechGestureAction(for deviceID: String) -> LogitechGestureAction {
        let actions = defaults.dictionary(forKey: Key.logitechGestureActions) as? [String: String]
        guard let raw = actions?[deviceID],
              let action = LogitechGestureAction(rawValue: raw) else {
            return .missionControl
        }
        return action
    }

    func setLogitechGestureAction(_ action: LogitechGestureAction, for deviceID: String) {
        var actions = defaults.dictionary(forKey: Key.logitechGestureActions) as? [String: String] ?? [:]
        actions[deviceID] = action.rawValue
        defaults.set(actions, forKey: Key.logitechGestureActions)
    }

    func logitechSideButtonAction(for deviceID: String, button: LogitechSideButton) -> LogitechSideButtonAction {
        let actions = defaults.dictionary(forKey: Key.logitechSideButtonActions) as? [String: String]
        guard let raw = actions?[logitechSideButtonKey(deviceID: deviceID, button: button)],
              let action = LogitechSideButtonAction(rawValue: raw) else {
            return button.defaultAction
        }
        return action
    }

    func setLogitechSideButtonAction(
        _ action: LogitechSideButtonAction,
        for deviceID: String,
        button: LogitechSideButton
    ) {
        var actions = defaults.dictionary(forKey: Key.logitechSideButtonActions) as? [String: String] ?? [:]
        actions[logitechSideButtonKey(deviceID: deviceID, button: button)] = action.rawValue
        defaults.set(actions, forKey: Key.logitechSideButtonActions)
    }

    func logitechDPI(for deviceID: String) -> Int? {
        let values = defaults.dictionary(forKey: Key.logitechDPIValues) as? [String: Int]
        return values?[deviceID]
    }

    func setLogitechDPI(_ dpi: Int, for deviceID: String) {
        var values = defaults.dictionary(forKey: Key.logitechDPIValues) as? [String: Int] ?? [:]
        values[deviceID] = dpi
        defaults.set(values, forKey: Key.logitechDPIValues)
    }

    private func logitechSideButtonKey(deviceID: String, button: LogitechSideButton) -> String {
        "\(deviceID):\(button.rawValue)"
    }
}
