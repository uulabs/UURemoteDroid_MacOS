import XCTest
import Darwin
@testable import RemoteDroidCore

final class ProtocolTests: XCTestCase {
    func testSessionPacketHeader() throws {
        let (reader, closePair) = try makeReader()
        defer { closePair() }

        var header = Data([0x80, 0x00, 0x00, 0x01])
        header.appendBigEndian(UInt32(1080))
        header.appendBigEndian(UInt32(2400))
        try write(header, to: reader.writeFD)

        guard case .session(let session) = try reader.reader.readNext() else {
            return XCTFail("Expected a session packet")
        }
        XCTAssertEqual(session.width, 1080)
        XCTAssertEqual(session.height, 2400)
        XCTAssertTrue(session.isClientResize)
    }

    func testMediaPacketHeaderAndKeyFrameFlag() throws {
        let (reader, closePair) = try makeReader()
        defer { closePair() }

        let payload = Data([0x00, 0x00, 0x00, 0x01, 0x65, 0xAA])
        var header = Data()
        let ptsAndFlags: UInt64 = (1 << 61) | 123_456
        header.appendBigEndian(ptsAndFlags)
        header.appendBigEndian(UInt32(payload.count))
        try write(header + payload, to: reader.writeFD)

        guard case .media(let media) = try reader.reader.readNext() else {
            return XCTFail("Expected a media packet")
        }
        XCTAssertEqual(media.pts, 123_456)
        XCTAssertTrue(media.isKeyFrame)
        XCTAssertFalse(media.isConfig)
        XCTAssertEqual(media.payload, payload)
    }

    func testConfigPacketFlag() throws {
        let (reader, closePair) = try makeReader()
        defer { closePair() }

        let payload = Data([0x00, 0x00, 0x00, 0x01, 0x67])
        var header = Data()
        header.appendBigEndian(UInt64(1 << 62))
        header.appendBigEndian(UInt32(payload.count))
        try write(header + payload, to: reader.writeFD)

        guard case .media(let media) = try reader.reader.readNext() else {
            return XCTFail("Expected a media packet")
        }
        XCTAssertTrue(media.isConfig)
        XCTAssertFalse(media.isKeyFrame)
    }

    func testKeycodeMessageBytes() {
        let data = ScrcpyControlMessage.keycode(action: .down, keycode: 3)
        let expected = Data([0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(data, expected)
    }

    func testTextMessageAndChunking() {
        let packets = ScrcpyControlMessage.text(String(repeating: "a", count: 650))
        XCTAssertEqual(packets.count, 3)
        XCTAssertEqual(packets[0].count, 305)
        XCTAssertEqual(packets[0][0], 1)
        XCTAssertEqual(packets[0][1...4], Data([0, 0, 1, 44]))
        XCTAssertEqual(packets[2].count, 55)
    }

    func testUnicodeChunkBoundary() {
        let text = String(repeating: "é", count: 200) // 400 bytes
        let packets = ScrcpyControlMessage.text(text)
        XCTAssertEqual(packets.count, 2)
        for packet in packets {
            let length = packet[0..<5].dropFirst().reduce(0) { ($0 << 8) | Int($1) }
            XCTAssertLessThanOrEqual(length, 300)
            let body = packet.dropFirst(5)
            XCTAssertNotNil(String(data: Data(body), encoding: .utf8))
        }
    }

    func testTouchMessageMatchesScrcpyWireFormat() {
        let data = ScrcpyControlMessage.touch(
            action: .down,
            pointerID: 0x1234_5678_8765_4321,
            x: 100,
            y: 200,
            screenWidth: 1080,
            screenHeight: 1920,
            pressure: 1,
            actionButton: AndroidButton.primary,
            buttons: AndroidButton.primary
        )
        let expected = Data([
            2, 0,
            0x12, 0x34, 0x56, 0x78, 0x87, 0x65, 0x43, 0x21,
            0x00, 0x00, 0x00, 0x64,
            0x00, 0x00, 0x00, 0xc8,
            0x04, 0x38, 0x07, 0x80,
            0xff, 0xff,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x01,
        ])
        XCTAssertEqual(data, expected)
    }

    func testScrollMessageMatchesScrcpyWireFormat() {
        let data = ScrcpyControlMessage.scroll(
            x: 260,
            y: 1026,
            screenWidth: 1080,
            screenHeight: 1920,
            horizontal: 16,
            vertical: -16,
            buttons: 1
        )
        XCTAssertEqual(data.count, 21)
        XCTAssertEqual(data, Data([
            3,
            0x00, 0x00, 0x01, 0x04,
            0x00, 0x00, 0x04, 0x02,
            0x04, 0x38, 0x07, 0x80,
            0x7F, 0xFF,
            0x80, 0x00,
            0x00, 0x00, 0x00, 0x01,
        ]))
    }

    func testSetClipboardMessageWireFormat() {
        let data = ScrcpyControlMessage.setClipboard(
            text: "hi",
            paste: true,
            sequence: 0x0102_0304_0506_0708
        )
        XCTAssertEqual(data, Data([
            9,
            1, 2, 3, 4, 5, 6, 7, 8,
            1,
            0, 0, 0, 2,
            0x68, 0x69,
        ]))
    }

    func testDeviceClipboardMessage() throws {
        let (readFD, writeFD, closePair) = try makeSocketPair()
        defer { closePair() }
        var data = Data([0])
        data.appendBigEndian(UInt32(5))
        data.append(Data("hello".utf8))
        try write(data, to: writeFD)
        XCTAssertEqual(try ScrcpyDeviceMessageReader.readNext(fd: readFD), .clipboard("hello"))
    }

    func testDeviceClipboardAckMessage() throws {
        let (readFD, writeFD, closePair) = try makeSocketPair()
        defer { closePair() }
        var data = Data([1])
        data.appendBigEndian(UInt64(42))
        try write(data, to: writeFD)
        XCTAssertEqual(try ScrcpyDeviceMessageReader.readNext(fd: readFD), .clipboardAck(42))
    }

    func testDeviceUhidMessageIsParsedAndDrained() throws {
        let (readFD, writeFD, closePair) = try makeSocketPair()
        defer { closePair() }
        var data = Data([2])
        data.appendBigEndian(UInt16(3))
        data.appendBigEndian(UInt16(2))
        data.append(Data([0xAB, 0xCD]))
        try write(data, to: writeFD)
        XCTAssertEqual(
            try ScrcpyDeviceMessageReader.readNext(fd: readFD),
            .uhidOutput(id: 3, data: Data([0xAB, 0xCD]))
        )
    }

    func testUnknownDeviceMessageThrows() throws {
        let (readFD, writeFD, closePair) = try makeSocketPair()
        defer { closePair() }
        try write(Data([99]), to: writeFD)
        XCTAssertThrowsError(try ScrcpyDeviceMessageReader.readNext(fd: readFD))
    }

    func testSamsungSafeServerCommandLength() {
        let command = ScrcpyCommand.serverCommand(scid: 0x1234_5678, configuration: .balanced)
        XCTAssertLessThan(command.utf8.count, 256)
        XCTAssertTrue(command.contains("audio=false"))
        XCTAssertTrue(command.contains("send_device_meta=false"))
        XCTAssertTrue(command.contains("max_size=1920"))
        XCTAssertFalse(command.contains("send_dummy_byte"))
        XCTAssertFalse(command.contains("clipboard_autosync"))
    }

    func testBladeConfigParameterSets() {
        let hex = "0000000167428029e90120122484040404161108d40000000168ce3c80"
        let data = Data(hexString: hex)
        let units = H264NALParser.nals(from: data)
        XCTAssertEqual(units.count, 2)
        XCTAssertEqual(units[0].count, 17)
        XCTAssertEqual(units[1].count, 4)
        let sets = H264NALParser.parameterSets(from: data)
        XCTAssertNotNil(sets)
        XCTAssertEqual(sets?.sps.count, 17)
        XCTAssertEqual(sets?.pps.count, 1)
        XCTAssertEqual(sets?.pps.first?.count, 4)
    }

    func testAVCCConversion() {
        let units = [Data([0x67, 0x42]), Data([0x68, 0xCE])]
        let converted = H264NALParser.avccSample(from: units)
        XCTAssertEqual(converted, Data([0, 0, 0, 2, 0x67, 0x42, 0, 0, 0, 2, 0x68, 0xCE]))
    }

    private func makeSocketPair() throws -> (Int32, Int32, () -> Void) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return (fds[0], fds[1], {
            Darwin.close(fds[0])
            Darwin.close(fds[1])
        })
    }

    private func makeReader() throws -> ((reader: ScrcpyStreamReader, writeFD: Int32), () -> Void) {
        var fds: [Int32] = [0, 0]
        let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        XCTAssertEqual(result, 0)
        let reader = ScrcpyStreamReader(fd: fds[0])
        return ((reader, fds[1]), {
            Darwin.close(fds[0])
            Darwin.close(fds[1])
        })
    }

    private func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let count = Darwin.send(fd, base.advanced(by: offset), data.count - offset, 0)
                guard count > 0 else { throw NSError(domain: "test", code: 1) }
                offset += count
            }
        }
    }
}

private extension Data {
    init(hexString: String) {
        var bytes: [UInt8] = []
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            bytes.append(UInt8(hexString[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
