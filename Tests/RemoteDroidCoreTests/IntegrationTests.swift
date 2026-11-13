import XCTest
@testable import RemoteDroidCore

final class IntegrationTests: XCTestCase {
    func testInstallAPK() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["UU_INTEGRATION"] == "1" else {
            throw XCTSkip("Set UU_INTEGRATION=1 and the ADB/serial/APK env vars to run")
        }
        guard let adbPath = environment["UU_ADB_PATH"],
              let serial = environment["UU_ADB_SERIAL"],
              let apkPath = environment["UU_TEST_APK"] else {
            throw XCTSkip("UU_ADB_PATH, UU_ADB_SERIAL and UU_TEST_APK are required")
        }
        let adb = ADBClient(executableURL: URL(fileURLWithPath: adbPath))
        let apk = URL(fileURLWithPath: apkPath)
        try await adb.install(apkURL: apk, serial: serial)
        let packages = try await adb.shell("pm list packages au.com.uulabs.remotedroid.smoketest", serial: serial)
        XCTAssertTrue(packages.contains("au.com.uulabs.remotedroid.smoketest"))
        _ = try? await adb.run(["-s", serial, "uninstall", "au.com.uulabs.remotedroid.smoketest"], timeout: 20)
    }

    func testSessionStartsAndInjectsHome() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["UU_INTEGRATION"] == "1" else {
            throw XCTSkip("Set UU_INTEGRATION=1 and the ADB/serial env vars to run")
        }
        guard let adbPath = environment["UU_ADB_PATH"],
              let serial = environment["UU_ADB_SERIAL"],
              environment["UU_SCRCPY_SERVER"] != nil else {
            throw XCTSkip("UU_ADB_PATH, UU_ADB_SERIAL and UU_SCRCPY_SERVER are required")
        }
        XCTAssertNotNil(ScrcpyServer.locate())
        let adb = ADBClient(executableURL: URL(fileURLWithPath: adbPath))
        _ = try? await adb.shell("input keyevent KEYCODE_WAKEUP", serial: serial)
        _ = try? await adb.shell("wm dismiss-keyguard", serial: serial)
        _ = try? await adb.shell("am start -a android.settings.SETTINGS", serial: serial)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let before = try await adb.shell("dumpsys window | grep mCurrentFocus", serial: serial)
        XCTAssertTrue(before.localizedCaseInsensitiveContains("settings"), "Expected Settings to be focused, got: \(before)")

        let device = AndroidDevice(serial: serial, state: .device)
        let session = ScrcpySession(adb: adb, device: device, configuration: .efficient)
        session.start()
        defer { session.stop() }

        var live = false
        for _ in 0..<100 {
            if case .live = session.phase { live = true; break }
            if case .failed(let message) = session.phase {
                XCTFail("Session failed: \(message)")
                return
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        XCTAssertTrue(live, "Session did not become live; phase=\(session.phase)")

        session.pressHome()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let after = try await adb.shell("dumpsys window | grep mCurrentFocus", serial: serial)
        XCTAssertFalse(after.localizedCaseInsensitiveContains("settings"), "Home was not injected; focus: \(after)")
    }

    func testPushRoundTrip() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["UU_INTEGRATION"] == "1" else {
            throw XCTSkip("Set UU_INTEGRATION=1 and the ADB/serial/scratch env vars to run")
        }
        guard let adbPath = environment["UU_ADB_PATH"],
              let serial = environment["UU_ADB_SERIAL"],
              let scratchPath = environment["UU_INTEGRATION_SCRATCH"] else {
            throw XCTSkip("UU_ADB_PATH, UU_ADB_SERIAL and UU_INTEGRATION_SCRATCH are required")
        }

        let adb = ADBClient(executableURL: URL(fileURLWithPath: adbPath))
        let remoteName = "remotedroid-integration-\(UUID().uuidString).txt"
        let remotePath = "/sdcard/Download/\(remoteName)"
        let localURL = URL(fileURLWithPath: scratchPath).appendingPathComponent(remoteName)
        let payload = Data((0..<512 * 1024).map { UInt8($0 % 251) })
        try payload.write(to: localURL)
        defer {
            try? FileManager.default.removeItem(at: localURL)
            Task { _ = try? await adb.run(["-s", serial, "shell", "rm", remotePath], timeout: 10) }
        }

        let progressBox = ProgressBox()
        try await adb.push(localURL: localURL, remoteName: remoteName, serial: serial) { value in
            progressBox.record(value)
        }
        XCTAssertTrue(progressBox.sawCompletion, "Push should finish at 100%")
        let output = try await adb.shell("wc -c < \(remotePath)", serial: serial)
        XCTAssertTrue(output.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("524288"), "Unexpected remote size: \(output)")
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lastValue: Double = 0

    var sawCompletion: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastValue >= 0.999
    }

    func record(_ value: Double) {
        lock.lock()
        lastValue = max(lastValue, value)
        lock.unlock()
    }
}
