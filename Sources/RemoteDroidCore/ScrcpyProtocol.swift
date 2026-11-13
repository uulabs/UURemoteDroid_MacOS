import Foundation

// MARK: - Stream framing

public enum ScrcpyVideoCodec: String, Equatable, Sendable {
    case h264
    case h265
    case av1
    case vp8
    case vp9

    public init?(identifier: String) {
        self.init(rawValue: identifier.lowercased())
    }
}

public struct ScrcpySessionPacket: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let isClientResize: Bool
}

public struct ScrcpyMediaPacket: Equatable, Sendable {
    public let pts: UInt64
    public let isConfig: Bool
    public let isKeyFrame: Bool
    public let payload: Data
}

public enum ScrcpyStreamPacket: Equatable, Sendable {
    case session(ScrcpySessionPacket)
    case media(ScrcpyMediaPacket)
}

public enum ScrcpyProtocolError: LocalizedError {
    case badCodec(String)
    case invalidHeader
    case packetTooLarge(UInt32)
    case unsupportedCodec(String)
    case unknownDeviceMessage(UInt8)

    public var errorDescription: String? {
        switch self {
        case .badCodec(let value): return "Unexpected video codec “\(value)”"
        case .invalidHeader: return "Invalid scrcpy stream header"
        case .packetTooLarge(let size): return "Video packet too large (\(size) bytes)"
        case .unsupportedCodec(let value): return "Unsupported video codec “\(value)”"
        case .unknownDeviceMessage(let type): return "Unknown scrcpy device message type \(type)"
        }
    }
}

public final class ScrcpyStreamReader {
    private let fd: Int32

    public init(fd: Int32) {
        self.fd = fd
    }

    public static func readCodec(fd: Int32) throws -> ScrcpyVideoCodec {
        let data = try SocketIO.readExactly(fd: fd, count: 4)
        let identifier = String(decoding: data, as: UTF8.self)
        guard let codec = ScrcpyVideoCodec(identifier: identifier) else {
            throw ScrcpyProtocolError.badCodec(identifier)
        }
        return codec
    }

    public func readNext() throws -> ScrcpyStreamPacket {
        let header = try SocketIO.readExactly(fd: fd, count: 12)
        guard header.count == 12 else { throw ScrcpyProtocolError.invalidHeader }
        let first = header[0]

        if first & 0x80 != 0 {
            let width = Int(Self.u32(header, 4))
            let height = Int(Self.u32(header, 8))
            let clientResize = (header[3] & 0x01) != 0
            guard width > 0, height > 0 else { throw ScrcpyProtocolError.invalidHeader }
            return .session(
                ScrcpySessionPacket(width: width, height: height, isClientResize: clientResize)
            )
        }

        let rawPTS = Self.u64(header, 0)
        let isConfig = (first & 0x40) != 0
        let isKeyFrame = (first & 0x20) != 0
        let pts = rawPTS & 0x1FFF_FFFF_FFFF_FFFF
        let size = Self.u32(header, 8)
        guard size <= 64 * 1024 * 1024 else {
            throw ScrcpyProtocolError.packetTooLarge(size)
        }
        let payload = try SocketIO.readExactly(fd: fd, count: Int(size))
        return .media(
            ScrcpyMediaPacket(
                pts: pts,
                isConfig: isConfig,
                isKeyFrame: isKeyFrame,
                payload: payload
            )
        )
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 {
            value = (value << 8) | UInt32(data[offset + index])
        }
        return value
    }

    static func u64(_ data: Data, _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(data[offset + index])
        }
        return value
    }
}

// MARK: - Android constants

public enum AndroidMotionAction: UInt8 {
    case down = 0
    case up = 1
    case move = 2
    case cancel = 3
    case outside = 4
    case hoverMove = 7
    case scroll = 8
}

public enum AndroidKeyAction: UInt8 {
    case down = 0
    case up = 1
    case multiple = 2
}

public enum AndroidKey {
    public static let home: UInt32 = 3
    public static let back: UInt32 = 4
    public static let volumeUp: UInt32 = 24
    public static let volumeDown: UInt32 = 25
    public static let power: UInt32 = 26
    public static let tab: UInt32 = 61
    public static let enter: UInt32 = 66
    public static let delete: UInt32 = 67
    public static let escape: UInt32 = 111
    public static let forwardDelete: UInt32 = 112
    public static let pageUp: UInt32 = 92
    public static let pageDown: UInt32 = 93
    public static let moveHome: UInt32 = 122
    public static let moveEnd: UInt32 = 123
    public static let insert: UInt32 = 124
    public static let menu: UInt32 = 82
    public static let appSwitch: UInt32 = 187
    public static let sleep: UInt32 = 223
    public static let wakeUp: UInt32 = 224
    public static let brightnessDown: UInt32 = 220
    public static let brightnessUp: UInt32 = 221
    public static let dpadUp: UInt32 = 19
    public static let dpadDown: UInt32 = 20
    public static let dpadLeft: UInt32 = 21
    public static let dpadRight: UInt32 = 22
    public static let dpadCenter: UInt32 = 23
    public static let mediaPlayPause: UInt32 = 85
    public static let mediaNext: UInt32 = 87
    public static let mediaPrevious: UInt32 = 88
    public static let volumeMute: UInt32 = 164
    public static let notification: UInt32 = 83
    public static let search: UInt32 = 84
    public static let settings: UInt32 = 176
}

public enum AndroidMeta {
    public static let shift: UInt32 = 0x0000_0001
    public static let alt: UInt32 = 0x0000_0002
    public static let sym: UInt32 = 0x0000_0004
    public static let control: UInt32 = 0x0000_1000
    public static let command: UInt32 = 0x0001_0000
}

public enum AndroidButton {
    public static let primary: UInt32 = 1
    public static let secondary: UInt32 = 2
    public static let tertiary: UInt32 = 4
    public static let back: UInt32 = 8
    public static let forward: UInt32 = 16
}

public enum AndroidKeycode {
    private static let letters: [Character: UInt32] = {
        var map: [Character: UInt32] = [:]
        for (offset, scalar) in "abcdefghijklmnopqrstuvwxyz".unicodeScalars.enumerated() {
            map[Character(String(scalar))] = UInt32(29 + offset)
        }
        return map
    }()

    private static let digits: [Character: UInt32] = {
        var map: [Character: UInt32] = [:]
        for offset in 0...9 {
            map[Character(String(offset))] = UInt32(7 + offset)
        }
        return map
    }()

    public static func forCharacter(_ character: Character) -> UInt32? {
        if let code = letters[character] { return code }
        if let code = digits[character] { return code }
        switch character {
        case " ": return 62
        case ",": return 55
        case ".": return 56
        case "-": return 69
        case "=": return 70
        case "[": return 71
        case "]": return 72
        case "\\": return 73
        case ";": return 74
        case "'": return 75
        case "/": return 76
        case "@": return 77
        case "+": return 81
        case "`": return 68
        default: return nil
        }
    }
}

// MARK: - Control messages

public enum ScrcpyControlMessage {
    public static let pointerIDMouse = UInt64.max

    public static func keycode(
        action: AndroidKeyAction,
        keycode: UInt32,
        repeatCount: UInt32 = 0,
        metaState: UInt32 = 0
    ) -> Data {
        var data = Data(capacity: 14)
        data.append(0)
        data.append(action.rawValue)
        data.appendBigEndian(keycode)
        data.appendBigEndian(repeatCount)
        data.appendBigEndian(metaState)
        return data
    }

    public static func text(_ text: String) -> [Data] {
        guard !text.isEmpty else { return [] }
        let maxBytes = 300
        var packets: [Data] = []
        var current = Data()
        for scalar in text.unicodeScalars {
            let bytes = Data(String(scalar).utf8)
            if current.count + bytes.count > maxBytes, !current.isEmpty {
                packets.append(textPacket(current))
                current.removeAll(keepingCapacity: true)
            }
            current.append(bytes)
        }
        if !current.isEmpty {
            packets.append(textPacket(current))
        }
        return packets
    }

    private static func textPacket(_ bytes: Data) -> Data {
        var data = Data(capacity: 5 + bytes.count)
        data.append(1)
        data.appendBigEndian(UInt32(bytes.count))
        data.append(bytes)
        return data
    }

    public static func touch(
        action: AndroidMotionAction,
        pointerID: UInt64 = pointerIDMouse,
        x: Int,
        y: Int,
        screenWidth: Int,
        screenHeight: Int,
        pressure: Float,
        actionButton: UInt32,
        buttons: UInt32
    ) -> Data {
        var data = Data(capacity: 32)
        data.append(2)
        data.append(action.rawValue)
        data.appendBigEndian(pointerID)
        data.appendBigEndian(UInt32(max(0, x)))
        data.appendBigEndian(UInt32(max(0, y)))
        data.appendBigEndian(UInt16(clamping: screenWidth))
        data.appendBigEndian(UInt16(clamping: screenHeight))
        data.appendBigEndian(UInt16((min(max(pressure, 0), 1) * 65_535).rounded()))
        data.appendBigEndian(actionButton)
        data.appendBigEndian(buttons)
        return data
    }

    public static func scroll(
        x: Int,
        y: Int,
        screenWidth: Int,
        screenHeight: Int,
        horizontal: Float,
        vertical: Float,
        buttons: UInt32
    ) -> Data {
        var data = Data(capacity: 21)
        data.append(3)
        data.appendBigEndian(UInt32(max(0, x)))
        data.appendBigEndian(UInt32(max(0, y)))
        data.appendBigEndian(UInt16(clamping: screenWidth))
        data.appendBigEndian(UInt16(clamping: screenHeight))
        data.appendBigEndian(i16FixedPoint(horizontal))
        data.appendBigEndian(i16FixedPoint(vertical))
        data.appendBigEndian(buttons)
        return data
    }

    public static func backOrScreenOn(action: AndroidKeyAction) -> Data {
        Data([4, action.rawValue])
    }

    public static func expandNotificationPanel() -> Data { Data([5]) }
    public static func expandSettingsPanel() -> Data { Data([6]) }
    public static func collapsePanels() -> Data { Data([7]) }
    public static func rotateDevice() -> Data { Data([11]) }
    public static func resetVideo() -> Data { Data([17]) }

    public static func setDisplayPower(on: Bool) -> Data {
        Data([10, on ? 1 : 0])
    }

    public static func setClipboard(text: String, paste: Bool, sequence: UInt64) -> Data {
        let textData = Data(text.utf8)
        var data = Data(capacity: 14 + textData.count)
        data.append(9)
        data.appendBigEndian(sequence)
        data.append(paste ? 1 : 0)
        data.appendBigEndian(UInt32(textData.count))
        data.append(textData)
        return data
    }

    public static func getClipboard(copyKey: UInt8 = 1) -> Data {
        Data([8, copyKey])
    }

    private static func i16FixedPoint(_ value: Float) -> Int16 {
        let normalized = min(max(value / 16, -1), 1)
        if normalized <= -1 { return Int16.min }
        if normalized >= 1 { return Int16.max }
        return Int16((normalized * 32_767).rounded())
    }
}

// MARK: - H.264 helpers

public enum H264NALParser {
    /// Returns NAL units without their Annex-B start codes.
    public static func nals(from data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(index: Int, length: Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                starts.append((index + 4, 4))
                index += 4
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append((index + 3, 3))
                index += 3
            } else {
                index += 1
            }
        }
        guard !starts.isEmpty else {
            // Some encoders emit AVCC-style length-prefixed config. Fall back to
            // treating the whole packet as one NAL only when it looks plausible.
            return data.isEmpty ? [] : [data]
        }

        var result: [Data] = []
        for (offset, startInfo) in starts.enumerated() {
            let start = startInfo.index
            let nextStart = offset + 1 < starts.count ? starts[offset + 1].index - starts[offset + 1].length : bytes.count
            if start < nextStart {
                result.append(Data(bytes[start..<nextStart]))
            }
        }
        return result
    }

    public static func parameterSets(from data: Data) -> (sps: Data, pps: [Data])? {
        var sps: Data?
        var pps: [Data] = []
        for nal in nals(from: data) where !nal.isEmpty {
            let type = nal[0] & 0x1F
            if type == 7 { sps = nal }
            if type == 8 { pps.append(nal) }
        }
        guard let sps, !pps.isEmpty else { return nil }
        return (sps, pps)
    }

    public static func avccSample(from nals: [Data]) -> Data {
        var data = Data()
        for nal in nals {
            data.appendBigEndian(UInt32(nal.count))
            data.append(nal)
        }
        return data
    }

    /// Reads the first four bytes as an AVCC length prefix when Annex-B start
    /// codes are absent. Returns nil when the data does not look length-prefixed.
    public static func lengthPrefixedNALs(from data: Data) -> [Data]? {
        guard data.count >= 4 else { return nil }
        var length = 0
        for byte in data.prefix(4) { length = (length << 8) | Int(byte) }
        guard length > 0, length + 4 <= data.count else { return nil }
        var result: [Data] = []
        var offset = 0
        while offset + 4 <= data.count {
            var size = 0
            for byte in data[offset..<(offset + 4)] { size = (size << 8) | Int(byte) }
            guard size > 0, offset + 4 + size <= data.count else { return nil }
            result.append(data.subdata(in: (offset + 4)..<(offset + 4 + size)))
            offset += 4 + size
        }
        return result.isEmpty ? nil : result
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}


// MARK: - Device messages (control socket, device -> computer)

public enum ScrcpyDeviceMessage: Equatable {
    case clipboard(String)
    case clipboardAck(UInt64)
    case uhidOutput(id: UInt16, data: Data)
}

public enum ScrcpyDeviceMessageReader {
    private static let clipboardMaxLength = 1 << 18

    public static func readNext(fd: Int32) throws -> ScrcpyDeviceMessage {
        let typeData = try SocketIO.readExactly(fd: fd, count: 1)
        let type = typeData[0]
        switch type {
        case 0:
            let lengthData = try SocketIO.readExactly(fd: fd, count: 4)
            var length = 0
            for byte in lengthData { length = (length << 8) | Int(byte) }
            guard length <= clipboardMaxLength else {
                throw ScrcpyProtocolError.packetTooLarge(UInt32(length))
            }
            let textData = try SocketIO.readExactly(fd: fd, count: length)
            let text = String(decoding: textData, as: UTF8.self)
            return .clipboard(text)
        case 1:
            let sequenceData = try SocketIO.readExactly(fd: fd, count: 8)
            var sequence: UInt64 = 0
            for byte in sequenceData { sequence = (sequence << 8) | UInt64(byte) }
            return .clipboardAck(sequence)
        case 2:
            let header = try SocketIO.readExactly(fd: fd, count: 4)
            let id = (UInt16(header[0]) << 8) | UInt16(header[1])
            let size = Int((UInt16(header[2]) << 8) | UInt16(header[3]))
            let data = try SocketIO.readExactly(fd: fd, count: size)
            return .uhidOutput(id: id, data: data)
        default:
            throw ScrcpyProtocolError.unknownDeviceMessage(type)
        }
    }
}
