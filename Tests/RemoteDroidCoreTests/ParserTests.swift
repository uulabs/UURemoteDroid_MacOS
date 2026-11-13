import XCTest
@testable import RemoteDroidCore

final class ParserTests: XCTestCase {
    func testDeviceListParsesThreeDevicesAndStates() {
        let output = """
        List of devices attached
        323961391497           device usb:271777792X product:Z3102T model:Blade_A3_Plus device:Z3102T transport_id:1
        S980000000000014309    device usb:271712256X product:S98_EEA model:S98 device:S98 transport_id:2
        emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:3
        ABC123                 unauthorized usb:1234 transport_id:4

        """
        let devices = ADBOutputParser.parseDevices(output)
        XCTAssertEqual(devices.count, 4)
        XCTAssertEqual(devices[0].serial, "323961391497")
        XCTAssertEqual(devices[0].state, .device)
        XCTAssertEqual(devices[0].connection, .usb)
        XCTAssertEqual(devices[2].connection, .emulator)
        XCTAssertEqual(devices[3].state, .unauthorized)
        XCTAssertEqual(devices[0].displayName, "Blade A3 Plus")
    }

    func testNoPermissionsBecomesOffline() {
        let output = """
        List of devices attached
        1234567890    no permissions (user in plugdev group; are your udev rules wrong?); see [http://developer.android.com/tools/device.html]
        """
        let devices = ADBOutputParser.parseDevices(output)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].state, .offline)
    }

    func testDetailsParser() {
        let output = """
        @@UU:MANUFACTURER@@
        Google
        @@UU:MODEL@@
        Pixel 9 Pro
        @@UU:DEVICENAME@@
        caiman
        @@UU:ANDROID@@
        15
        @@UU:SDK@@
        35
        @@UU:QEMU@@
        0
        @@UU:SIZE@@
        Physical size: 1280x2856
        Override size: 1080x2400
        @@UU:DENSITY@@
        Physical density: 480
        Override density: 420
        @@UU:BATTERY@@
        AC powered: false
        USB powered: true
        status: 2
        level: 87
        @@UU:STORAGE@@
        42G
        """
        let details = ADBOutputParser.parseDetails(output)
        XCTAssertEqual(details.model, "Pixel 9 Pro")
        XCTAssertEqual(details.manufacturer, "Google")
        XCTAssertEqual(details.androidVersion, "15")
        XCTAssertEqual(details.screenWidth, 1080)
        XCTAssertEqual(details.screenHeight, 2400)
        XCTAssertEqual(details.density, 420)
        XCTAssertEqual(details.batteryLevel, 87)
        XCTAssertTrue(details.isCharging)
        XCTAssertEqual(details.storageFree, "42G")
        XCTAssertFalse(details.isEmulator)
    }

    func testResolutionPrefersOverride() {
        let result = ADBOutputParser.parseResolution([
            "Physical size: 1080x2400",
            "Override size: 720x1600",
        ])
        XCTAssertEqual(result?.width, 720)
        XCTAssertEqual(result?.height, 1600)
    }

    func testStreamConfigurationLabels() {
        XCTAssertEqual(StreamConfiguration.balanced.summary, "1920 px · 60 fps · 24 Mbps")
        XCTAssertEqual(StreamConfiguration.native.summary, "Native · Display · 32 Mbps")
        XCTAssertEqual(StreamConfiguration.efficient.summary, "1280 px · 30 fps · 8 Mbps")
    }
}
