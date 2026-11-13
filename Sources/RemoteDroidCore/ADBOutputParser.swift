import Foundation

public enum ADBOutputParser {
    public static let markerPrefix = "@@UU:"
    public static let markerSuffix = "@@"

    public static func parseDevices(_ output: String) -> [AndroidDevice] {
        var devices: [AndroidDevice] = []
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard !line.hasPrefix("List of devices attached") else { continue }
            guard !line.hasPrefix("*") else { continue }

            if line.contains("no permissions") {
                let serial = line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? line
                devices.append(AndroidDevice(serial: serial, state: .offline))
                continue
            }

            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2 else { continue }
            let serial = parts[0]
            let rawState = parts[1]
            let state = DeviceState(rawValue: rawState) ?? .unknown

            var product: String?
            var model: String?
            var deviceCode: String?
            var transportId: String?
            for token in parts.dropFirst(2) {
                guard let separator = token.firstIndex(where: { $0 == "=" || $0 == ":" }) else { continue }
                let key = String(token[..<separator])
                let value = String(token[token.index(after: separator)...])
                switch key {
                case "product": product = value
                case "model": model = value
                case "device": deviceCode = value
                case "transport_id": transportId = value
                default: break
                }
            }

            devices.append(
                AndroidDevice(
                    serial: serial,
                    state: state,
                    product: product,
                    model: model,
                    deviceCode: deviceCode,
                    transportId: transportId
                )
            )
        }
        return devices
    }

    /// One round-trip shell command that collects everything the console shows.
    public static let deviceInfoCommand: String = {
        func section(_ key: String, _ command: String) -> String {
            "echo \(markerPrefix)\(key)\(markerSuffix); \(command)"
        }
        return [
            section("MANUFACTURER", "getprop ro.product.manufacturer"),
            section("MODEL", "getprop ro.product.model"),
            section("DEVICENAME", "getprop ro.product.device"),
            section("ANDROID", "getprop ro.build.version.release"),
            section("SDK", "getprop ro.build.version.sdk"),
            section("QEMU", "getprop ro.kernel.qemu"),
            section("SIZE", "wm size"),
            section("DENSITY", "wm density"),
            section("BATTERY", "dumpsys battery"),
            section("STORAGE", "df -h /data 2>/dev/null | tail -1 | awk '{print $4}'"),
        ].joined(separator: "; ")
    }()

    public static func parseDetails(_ output: String) -> DeviceDetails {
        var sections: [String: [String]] = [:]
        var current: String?
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix(markerPrefix), line.hasSuffix(markerSuffix) {
                let key = String(line.dropFirst(markerPrefix.count).dropLast(markerSuffix.count))
                current = key
                sections[key, default: []] = []
                continue
            }
            guard let current else { continue }
            sections[current, default: []].append(line)
        }

        var details = DeviceDetails()
        details.manufacturer = firstValue(sections["MANUFACTURER"]) ?? ""
        details.model = firstValue(sections["MODEL"]) ?? ""
        details.deviceName = firstValue(sections["DEVICENAME"]) ?? ""
        details.androidVersion = firstValue(sections["ANDROID"]) ?? ""
        details.sdkVersion = firstValue(sections["SDK"]) ?? ""
        details.isEmulator = (firstValue(sections["QEMU"]) == "1") ||
            details.model.localizedCaseInsensitiveContains("sdk_gphone") ||
            details.model.localizedCaseInsensitiveContains("emulator")

        if let size = parseResolution(sections["SIZE"] ?? []) {
            details.screenWidth = size.width
            details.screenHeight = size.height
        }
        if let density = parseDensity(sections["DENSITY"] ?? []) {
            details.density = density
        }

        let battery = parseBattery(sections["BATTERY"] ?? [])
        details.batteryLevel = battery.level
        details.isCharging = battery.charging
        details.storageFree = firstValue(sections["STORAGE"]) ?? ""

        return details
    }

    public static func parseResolution(_ lines: [String]) -> (width: Int, height: Int)? {
        var physical: (Int, Int)?
        var override: (Int, Int)?
        for line in lines {
            guard let match = line.range(of: #"([0-9]{2,5})x([0-9]{2,5})"#, options: .regularExpression) else {
                continue
            }
            let tokens = line[match].split(separator: "x")
            guard tokens.count == 2, let width = Int(tokens[0]), let height = Int(tokens[1]) else {
                continue
            }
            if line.localizedCaseInsensitiveContains("override") {
                override = (width, height)
            } else {
                physical = (width, height)
            }
        }
        return override ?? physical
    }

    public static func parseDensity(_ lines: [String]) -> Int? {
        var physical: Int?
        var override: Int?
        for line in lines {
            guard let digits = line.split(whereSeparator: { !$0.isNumber }).last,
                  let value = Int(digits) else { continue }
            if line.localizedCaseInsensitiveContains("override") {
                override = value
            } else {
                physical = value
            }
        }
        return override ?? physical
    }

    public static func parseBattery(_ lines: [String]) -> (level: Int, charging: Bool) {
        var level = -1
        var status = -1
        var plugged = 0
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "level": level = Int(parts[1]) ?? -1
            case "status": status = Int(parts[1]) ?? -1
            case "plugged": plugged = Int(parts[1]) ?? 0
            default: break
            }
        }
        return (level, status == 2 || status == 5 || plugged > 0)
    }

    /// Parses a `df -h` available-space field. Keeps the human-readable unit and
    /// fixes the occasional "0" that some toybox versions print for unavailable.
    public static func parseStorage(_ output: String) -> String {
        firstValue([output]) ?? ""
    }

    private static func firstValue(_ lines: [String]?) -> String? {
        guard let lines else { return nil }
        return lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
