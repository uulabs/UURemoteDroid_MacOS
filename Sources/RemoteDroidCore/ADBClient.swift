import Foundation

public struct ADBError: LocalizedError, Sendable {
    public let message: String
    public let output: String
    public let exitCode: Int32?

    public init(_ message: String, output: String = "", exitCode: Int32? = nil) {
        self.message = message
        self.output = output
        self.exitCode = exitCode
    }

    public var errorDescription: String? {
        if output.isEmpty { return message }
        return "\(message)\n\(output.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

public final class ADBClient: @unchecked Sendable {
    public let executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    // MARK: Locating adb

    public static func candidatePaths() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [
            home.appendingPathComponent("Library/Android/sdk/platform-tools/adb"),
            URL(fileURLWithPath: "/opt/homebrew/bin/adb"),
            URL(fileURLWithPath: "/usr/local/bin/adb"),
            URL(fileURLWithPath: "/usr/bin/adb"),
        ]
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            candidates.append(URL(fileURLWithPath: String(directory)).appendingPathComponent("adb"))
        }
        return candidates
    }

    public static func resolveADB(customPath: String? = nil) -> URL? {
        var seen = Set<String>()
        var paths: [URL] = []
        if let customPath, !customPath.isEmpty {
            paths.append(URL(fileURLWithPath: customPath))
        }
        if let env = ProcessInfo.processInfo.environment["ADB"], !env.isEmpty {
            paths.append(URL(fileURLWithPath: env))
        }
        paths.append(contentsOf: candidatePaths())
        for url in paths where seen.insert(url.path).inserted {
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    public static func version(for url: URL) -> String? {
        let process = Process()
        process.executableURL = url
        process.arguments = ["version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .first
                .map(String.init)
        } catch {
            return nil
        }
    }

    // MARK: Commands

    public func listDevices() async throws -> [AndroidDevice] {
        let output = try await run(["devices", "-l"], timeout: 15)
        return ADBOutputParser.parseDevices(output)
    }

    public func loadDetails(for serial: String) async -> DeviceDetails? {
        do {
            let output = try await run(
                ["-s", serial, "shell", ADBOutputParser.deviceInfoCommand],
                timeout: 12
            )
            guard !output.isEmpty else { return nil }
            return ADBOutputParser.parseDetails(output)
        } catch {
            return nil
        }
    }

    public func shell(_ command: String, serial: String, timeout: TimeInterval = 20) async throws -> String {
        try await run(["-s", serial, "shell", command], timeout: timeout)
    }

    public func screenshot(serial: String) async throws -> Data {
        try await runData(["-s", serial, "exec-out", "screencap", "-p"], timeout: 20)
    }

    /// Streams a file to the device's Download directory.
    public func push(
        localURL: URL,
        remoteName: String,
        serial: String,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let remotePath = "/sdcard/Download/\(remoteName)"
        let result = try await launch(
            arguments: ["-s", serial, "push", localURL.path, remotePath],
            timeout: 60 * 30
        ) { data in
            guard let progress else { return }
            let text = String(decoding: data, as: UTF8.self)
            if let percent = Self.lastPercentage(in: text) {
                progress(percent)
            }
        }

        guard result.status == 0 else {
            throw ADBError("Could not send \(localURL.lastPathComponent)", output: result.output, exitCode: result.status)
        }
        progress?(1)

        // Best effort: make the file visible to gallery/file apps immediately.
        if let encoded = remotePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            _ = try? await run(
                ["-s", serial, "shell", "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file://\(encoded)"],
                timeout: 10
            )
        }
    }

    public func install(apkURL: URL, serial: String) async throws {
        let result = try await launch(
            arguments: ["-s", serial, "install", "-r", apkURL.path],
            timeout: 60 * 10
        )
        guard result.status == 0, result.output.localizedCaseInsensitiveContains("Success") else {
            throw ADBError("Could not install \(apkURL.lastPathComponent)", output: result.output, exitCode: result.status)
        }
    }

    public func removeReverse(port: UInt16, serial: String) async {
        _ = try? await run(
            ["-s", serial, "reverse", "--remove", "tcp:\(port)"],
            timeout: 8
        )
    }

    public func addReverse(port: UInt16, scid: UInt32, serial: String) async throws {
        let hex = String(format: "%08x", scid)
        _ = try await run(
            ["-s", serial, "reverse", "localabstract:scrcpy_\(hex)", "tcp:\(port)"],
            timeout: 10
        )
    }

    public func killServer(scid: UInt32, serial: String) async {
        let hex = String(format: "%08x", scid)
        _ = try? await run(
            ["-s", serial, "shell", "pkill -f 'scrcpy.Server.*scid=\(hex)'"],
            timeout: 8
        )
    }

    public func makeProcess(arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        return process
    }

    // MARK: Process plumbing

    public struct ProcessResult: Sendable {
        public let output: String
        public let status: Int32
    }

    private struct RawResult {
        let data: Data
        let status: Int32
        let timedOut: Bool
        var output: String { String(decoding: data, as: UTF8.self) }
    }

    public func run(_ arguments: [String], timeout: TimeInterval = 30) async throws -> String {
        let result = try await launch(arguments: arguments, timeout: timeout)
        guard result.status == 0 else {
            throw ADBError("ADB command failed: adb \(arguments.joined(separator: " "))", output: result.output, exitCode: result.status)
        }
        return result.output
    }

    public func runData(_ arguments: [String], timeout: TimeInterval = 30) async throws -> Data {
        let result = try await launch(arguments: arguments, timeout: timeout)
        guard result.status == 0 else {
            throw ADBError("ADB command failed", output: result.output, exitCode: result.status)
        }
        return result.data
    }

    /// Starts a long-lived process (the scrcpy server), keeping its output in a
    /// bounded buffer and surfacing the exit status.
    public func spawnServer(
        serial: String,
        command: String,
        onLog: @escaping @Sendable (String) -> Void
    ) throws -> (process: Process, stop: @Sendable () -> Void) {
        let process = makeProcess(arguments: ["-s", serial, "shell", command])
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let lock = NSLock()
        var log = ""
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            lock.lock()
            log.append(text)
            if log.count > 32_000 {
                log = String(log.suffix(24_000))
            }
            lock.unlock()
            onLog(text)
        }

        try process.run()

        let stop: @Sendable () -> Void = {
            handle.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            }
        }
        return (process, stop)
    }

    private func launch(
        arguments: [String],
        timeout: TimeInterval,
        onOutput: (@Sendable (Data) -> Void)? = nil
    ) async throws -> RawResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = self.executableURL
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let state = ProcessCaptureState()
            let handle = pipe.fileHandleForReading

            handle.readabilityHandler = { fileHandle in
                let data = fileHandle.availableData
                if data.isEmpty {
                    fileHandle.readabilityHandler = nil
                    return
                }
                state.append(data)
                onOutput?(data)
            }

            let finish: @Sendable (Int32) -> Void = { status in
                guard state.markFinished() else { return }
                handle.readabilityHandler = nil
                state.timeoutWorkItem?.cancel()
                let remaining = handle.readDataToEndOfFile()
                if !remaining.isEmpty {
                    state.append(remaining)
                }
                if state.timedOut {
                    continuation.resume(throwing: ADBError("ADB command timed out", output: state.output))
                } else {
                    continuation.resume(returning: RawResult(data: state.data, status: status, timedOut: false))
                }
            }

            process.terminationHandler = { terminated in
                finish(terminated.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                state.markFinished()
                handle.readabilityHandler = nil
                continuation.resume(throwing: ADBError("Could not launch adb: \(error.localizedDescription)"))
                return
            }

            let timeoutWork = DispatchWorkItem {
                state.markTimedOut()
                if process.isRunning {
                    process.terminate()
                }
            }
            state.timeoutWorkItem = timeoutWork
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        }
    }

    private static func lastPercentage(in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"([0-9]{1,3})\s*%"#) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        guard let last = matches.last, let matchRange = Range(last.range(at: 1), in: text) else {
            return nil
        }
        guard let value = Double(text[matchRange]) else { return nil }
        return min(max(value / 100, 0), 1)
    }
}

private final class ProcessCaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()
    private var _finished = false
    private var _timedOut = false
    var timeoutWorkItem: DispatchWorkItem?

    func append(_ chunk: Data) {
        lock.lock()
        _data.append(chunk)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return _data
    }

    var output: String {
        String(decoding: data, as: UTF8.self)
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _timedOut
    }

    func markTimedOut() {
        lock.lock()
        _timedOut = true
        lock.unlock()
    }

    @discardableResult
    func markFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if _finished { return false }
        _finished = true
        return true
    }
}
