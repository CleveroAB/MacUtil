import Foundation

enum LogitechGestureAction: String, CaseIterable {
    case disabled
    case missionControl

    var title: String {
        switch self {
        case .disabled:
            return "Disabled"
        case .missionControl:
            return "Mission Control"
        }
    }
}

enum LogitechSideButton: String, CaseIterable {
    case back
    case forward

    var title: String {
        switch self {
        case .back:
            return "Back Side Button"
        case .forward:
            return "Forward Side Button"
        }
    }

    var defaultAction: LogitechSideButtonAction {
        switch self {
        case .back:
            return .browserBack
        case .forward:
            return .browserForward
        }
    }

    init?(mouseButtonNumber: Int) {
        switch mouseButtonNumber {
        case 3:
            self = .back
        case 4:
            self = .forward
        default:
            return nil
        }
    }
}

enum LogitechSideButtonAction: String, CaseIterable {
    case disabled
    case browserBack
    case browserForward

    var title: String {
        switch self {
        case .disabled:
            return "Disabled"
        case .browserBack:
            return "Page Back"
        case .browserForward:
            return "Page Forward"
        }
    }
}

enum LogitechDeviceRoute: Hashable {
    case bolt(receiverID: String, slot: UInt8)
    case direct(vendorID: UInt16, productID: UInt16)

    var deviceIndex: UInt8 {
        switch self {
        case .bolt(_, let slot):
            return slot
        case .direct:
            return 0xff
        }
    }

    var stableID: String {
        switch self {
        case .bolt(let receiverID, let slot):
            return "bolt:\(receiverID):\(slot)"
        case .direct(let vendorID, let productID):
            return String(format: "direct:%04x:%04x", vendorID, productID)
        }
    }
}

struct LogitechDPIInfo: Equatable {
    var current: UInt16
    var values: [UInt16]

    var min: UInt16? { values.min() }
    var max: UInt16? { values.max() }

    func nearest(to dpi: Int) -> UInt16? {
        values.min { lhs, rhs in
            abs(Int(lhs) - dpi) < abs(Int(rhs) - dpi)
        }
    }
}

struct LogitechDeviceSnapshot: Equatable {
    var id: String { route.stableID }
    var name: String
    var route: LogitechDeviceRoute
    var batteryPercentage: Int?
    var dpi: LogitechDPIInfo?
    var supportsGestureButton: Bool
    var isOnline: Bool
    var lastError: String?

    var batteryTitle: String {
        guard let batteryPercentage else { return "--" }
        return "\(batteryPercentage)%"
    }
}
