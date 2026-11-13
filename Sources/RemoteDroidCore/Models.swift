import Foundation
import CoreGraphics

// MARK: - Devices

public enum DeviceState: String, Equatable, Sendable {
    case device
    case unauthorized
    case offline
    case connecting
    case recovery
    case unknown

    public var isUsable: Bool { self == .device }
}

public enum DeviceConnection: String, Equatable, Sendable {
    case usb
    case emulator
    case wifi
    case unknown

    public var label: String {
        switch self {
        case .usb: return "USB"
        case .emulator: return "EMULATOR"
        case .wifi: return "WI-FI"
        case .unknown: return "ADB"
        }
    }

    public var symbol: String {
        switch self {
        case .usb: return "cable.connector"
        case .emulator: return "display"
        case .wifi: return "wifi"
        case .unknown: return "link"
        }
    }
}

public struct DeviceDetails: Equatable, Sendable {
    public var manufacturer: String = ""
    public var model: String = ""
    public var androidVersion: String = ""
    public var sdkVersion: String = ""
    public var screenWidth: Int = 0
    public var screenHeight: Int = 0
    public var density: Int = 0
    public var batteryLevel: Int = -1
    public var isCharging: Bool = false
    public var storageFree: String = ""
    public var isEmulator: Bool = false
    public var deviceName: String = ""

    public init() {}

    public var androidDescription: String {
        guard !androidVersion.isEmpty else { return "Android" }
        return "Android \(androidVersion)"
    }

    public var screenDescription: String {
        guard screenWidth > 0, screenHeight > 0 else { return "—" }
        return "\(screenWidth) × \(screenHeight)"
    }

    public var batteryDescription: String {
        batteryLevel < 0 ? "—" : "\(batteryLevel)%"
    }

    public var storageDescription: String {
        storageFree.isEmpty ? "—" : storageFree
    }
}

public struct AndroidDevice: Identifiable, Equatable, Sendable {
    public var id: String { serial }
    public let serial: String
    public var state: DeviceState
    public var product: String?
    public var model: String?
    public var deviceCode: String?
    public var transportId: String?
    public var details: DeviceDetails?

    public init(
        serial: String,
        state: DeviceState,
        product: String? = nil,
        model: String? = nil,
        deviceCode: String? = nil,
        transportId: String? = nil,
        details: DeviceDetails? = nil
    ) {
        self.serial = serial
        self.state = state
        self.product = product
        self.model = model
        self.deviceCode = deviceCode
        self.transportId = transportId
        self.details = details
    }

    public var displayName: String {
        let candidate = details?.model ?? model
        if let candidate, !candidate.isEmpty {
            let normalized = candidate.replacingOccurrences(of: "_", with: " ")
            let lower = candidate.lowercased()
            if serial.hasPrefix("emulator-")
                || details?.isEmulator == true
                || lower.contains("sdk_gphone")
                || lower.contains("emulator") {
                return "Android Emulator"
            }
            return normalized
        }
        if serial.hasPrefix("emulator-") {
            return "Android Emulator"
        }
        return serial
    }

    public var connection: DeviceConnection {
        if serial.hasPrefix("emulator-") || details?.isEmulator == true {
            return .emulator
        }
        if serial.contains(":") {
            return .wifi
        }
        if state == .device {
            return .usb
        }
        return .unknown
    }

    public var shortSerial: String {
        if serial.count > 22 {
            return "…" + serial.suffix(20)
        }
        return serial
    }

    public var isReady: Bool { state.isUsable }
}

// MARK: - Streaming preferences

public struct StreamConfiguration: Equatable, Sendable {
    /// Longest video edge in pixels. 0 means native.
    public var maxSize: Int
    /// 0 means no explicit frame-rate cap.
    public var maxFPS: Int
    public var bitRate: Int
    public var keepAwake: Bool

    public init(maxSize: Int = 1920, maxFPS: Int = 60, bitRate: Int = 24_000_000, keepAwake: Bool = true) {
        self.maxSize = maxSize
        self.maxFPS = maxFPS
        self.bitRate = bitRate
        self.keepAwake = keepAwake
    }

    public var resolutionLabel: String {
        maxSize == 0 ? "Native" : "\(maxSize) px"
    }

    public var frameRateLabel: String {
        maxFPS == 0 ? "Display" : "\(maxFPS) fps"
    }

    public var bitRateLabel: String {
        String(format: "%.0f Mbps", Double(bitRate) / 1_000_000)
    }

    public var summary: String {
        "\(resolutionLabel) · \(frameRateLabel) · \(bitRateLabel)"
    }

    public static let balanced = StreamConfiguration()
    public static let native = StreamConfiguration(maxSize: 0, maxFPS: 0, bitRate: 32_000_000)
    public static let efficient = StreamConfiguration(maxSize: 1280, maxFPS: 30, bitRate: 8_000_000)
}
