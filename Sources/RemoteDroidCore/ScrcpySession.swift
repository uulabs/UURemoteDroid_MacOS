import Foundation
import AVFoundation

public enum ScrcpySessionPhase: Equatable {
    case idle
    case connecting
    case live
    case failed(String)

    public var isLive: Bool { self == .live }
}

/// One independent scrcpy connection. Sessions are safe to keep alive in the
/// background while the user switches between devices.
public final class ScrcpySession: ObservableObject, Identifiable, @unchecked Sendable {
    public let id: String
    public let device: AndroidDevice
    public let configuration: StreamConfiguration

    @Published public private(set) var phase: ScrcpySessionPhase = .idle
    @Published public private(set) var videoSize: CGSize = .zero
    @Published public private(set) var fps: Double = 0
    @Published public private(set) var bitrateMbps: Double = 0
    @Published public private(set) var totalFrames: UInt64 = 0
    @Published public private(set) var transportError: String?
    /// The phone's own screen: true = on, false = off/asleep, nil = unknown.
    @Published public private(set) var screenOn: Bool?

    /// Called on the main thread when the device changes its clipboard.
    public var onClipboardText: ((String) -> Void)?
    /// Called on the main thread once video metadata is available.
    public var onLive: (() -> Void)?

    public var displayLayer: AVSampleBufferDisplayLayer { decoder.displayLayer }

    private let adb: ADBClient
    private let decoder: H264VideoDecoder
    private let stateLock = NSLock()
    private let counterLock = NSLock()
    private let geometryLock = NSLock()

    private var stopped = true
    private var currentRun: UUID?
    private var videoFD: Int32 = -1
    private var controlFD: Int32 = -1
    private var listener: LoopbackTCPServer?
    private var serverProcess: Process?
    private var serverStop: (@Sendable () -> Void)?
    private var scid: UInt32?
    private var reversePort: UInt16?
    private var serverLog = ""
    private var streamSize: CGSize = .zero
    private var hasDisplayBeenAttached = false
    private var displayAttachmentTokens: Set<UUID> = []
    private var lastDisplayRefresh = Date.distantPast

    private var frameCounter = 0
    /// Running frame total, guarded by counterLock. The @Published
    /// totalFrames copy is only ever written on the main thread: writing a
    /// published property from the video queue makes SwiftUI lay out on that
    /// queue and wait for the main thread, which deadlocks against the stats
    /// timer waiting for counterLock (the app then hangs with a beachball).
    private var frameTotal: UInt64 = 0
    private var byteCounter = 0
    #if DEBUG
    private var mediaPacketCount = 0
    #endif
    private var statsTimer: Timer?

    // Stream health. All of these are touched on the main thread except
    // lastPacketAt / lastKeyframeRequest, which are guarded by their locks.
    private var lastPacketAt = Date()
    private var lastKeyframeRequest = Date.distantPast
    private var probeSentAt: Date?
    private var livenessCheckInFlight = false
    private var lastScreenCheck = Date.distantPast
    private var screenPollInFlight = false
    private var screenPollFailures = 0
    /// How often the phone's real screen state is read over ADB. Some phones
    /// keep sending their lock screen after the panel turns off, so frame
    /// activity cannot tell whether the screen is on.
    private static let screenPollInterval: TimeInterval = 4
    /// Seconds without any video packet before the session asks for a fresh
    /// keyframe to prove the stream is still alive.
    private static let silenceBeforeProbe: TimeInterval = 10
    /// Seconds a probe may go unanswered before the device is checked.
    private static let probeTimeout: TimeInterval = 6
    /// A session that has not produced video by then is restarted.
    private static let startDeadline: TimeInterval = 60

    private let startQueue = DispatchQueue(label: "au.com.uulabs.remotedroid.start")
    private let videoQueue = DispatchQueue(label: "au.com.uulabs.remotedroid.video", qos: .userInteractive)
    private let controlReadQueue = DispatchQueue(label: "au.com.uulabs.remotedroid.control.read")
    private let controlWriteQueue = DispatchQueue(label: "au.com.uulabs.remotedroid.control.write", qos: .userInteractive)

    public init(adb: ADBClient, device: AndroidDevice, configuration: StreamConfiguration) {
        self.id = device.serial
        self.adb = adb
        self.device = device
        self.configuration = configuration
        self.decoder = H264VideoDecoder()
        #if DEBUG
        decoder.debugLabel = "…\(device.serial.suffix(8))"
        #endif
    }

    deinit {
        stateLock.lock()
        let video = videoFD
        let control = controlFD
        let listener = self.listener
        let process = serverProcess
        let stopServer = serverStop
        stopped = true
        currentRun = nil
        videoFD = -1
        controlFD = -1
        self.listener = nil
        serverProcess = nil
        serverStop = nil
        stateLock.unlock()
        if video >= 0 { SocketIO.shutdown(video) }
        if control >= 0 { SocketIO.shutdown(control) }
        listener?.close()
        if let process, process.isRunning { stopServer?() }
    }

    // MARK: - Lifecycle

    public func start() {
        stateLock.lock()
        if !stopped {
            stateLock.unlock()
            return
        }
        stopped = false
        let run = UUID()
        currentRun = run
        stateLock.unlock()

        stateLock.lock()
        serverLog = ""
        stateLock.unlock()
        geometryLock.lock()
        streamSize = .zero
        geometryLock.unlock()
        resetCounters()
        #if DEBUG
        print("[session] start \(device.serial) maxSize=\(configuration.maxSize) fps=\(configuration.maxFPS) bitrate=\(configuration.bitRate)")
        #endif
        DispatchQueue.main.async {
            self.phase = .connecting
            self.transportError = nil
            self.videoSize = .zero
            self.fps = 0
            self.bitrateMbps = 0
        }

        Task { [weak self] in
            await self?.launch(run: run)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startDeadline) { [weak self] in
            guard let self, self.isActive(run) else { return }
            if self.phase != .live || self.videoSize == .zero {
                let log = self.lastServerLog()
                let message = "Timed out starting the stream." + (log.isEmpty ? "" : "\n\n\(log)")
                self.teardown(phase: .failed(message), reason: message)
            }
        }
    }

    public func stop() {
        teardown(phase: .idle, reason: nil)
    }

    private func teardown(phase: ScrcpySessionPhase, reason: String?) {
        stateLock.lock()
        if stopped, phase == .idle {
            stateLock.unlock()
            return
        }
        if stopped, currentRun == nil, case .failed = phase {
            stateLock.unlock()
            return
        }
        stopped = true
        currentRun = nil

        let video = videoFD
        let control = controlFD
        let closeListener = listener
        let process = serverProcess
        let stopServer = serverStop
        let port = reversePort
        let id = scid
        videoFD = -1
        controlFD = -1
        listener = nil
        serverProcess = nil
        serverStop = nil
        reversePort = nil
        scid = nil
        stateLock.unlock()

        if video >= 0 { SocketIO.shutdown(video) }
        if control >= 0 { SocketIO.shutdown(control) }
        closeListener?.close()
        videoQueue.async { [weak self] in self?.decoder.reset() }

        let serial = device.serial
        let adb = self.adb
        let removePort = port
        let removeScid = id

        Task.detached {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let process, process.isRunning {
                stopServer?()
            }
            if let removePort {
                await adb.removeReverse(port: removePort, serial: serial)
            }
            if let removeScid {
                await adb.killServer(scid: removeScid, serial: serial)
            }
        }

        DispatchQueue.main.async {
            if let reason {
                self.transportError = reason
                #if DEBUG
                print("[session] failed \(self.device.serial): \(reason)")
                #endif
            } else {
                #if DEBUG
                print("[session] stopped \(self.device.serial)")
                #endif
            }
            self.statsTimer?.invalidate()
            self.statsTimer = nil
            self.probeSentAt = nil
            self.livenessCheckInFlight = false
            self.phase = phase
            self.fps = 0
            self.bitrateMbps = 0
            if phase == .idle {
                self.videoSize = .zero
            }
        }
    }

    // MARK: - Startup

    private func launch(run: UUID) async {
        do {
            guard isActive(run) else { return }
            guard let serverURL = ScrcpyServer.locate() else {
                throw ADBError("The bundled scrcpy server is missing. Rebuild the app with Resources/\(ScrcpyServer.fileName).")
            }

            _ = try await adb.run(
                ["-s", device.serial, "push", serverURL.path, ScrcpyServer.remotePath],
                timeout: 30
            )
            guard isActive(run) else { return }

            let listener = try LoopbackTCPServer()
            let port = listener.port
            let newScid = UInt32.random(in: 1...0x7FFF_FFFF)
            withStateLock {
                self.listener = listener
                self.reversePort = port
                self.scid = newScid
            }

            try await adb.addReverse(port: port, scid: newScid, serial: device.serial)
            guard isActive(run) else {
                listener.close()
                return
            }

            let command = serverCommand(scid: newScid)
            let spawned = try adb.spawnServer(serial: device.serial, command: command) { [weak self] chunk in
                self?.appendServerLog(chunk)
            }
            withStateLock {
                self.serverProcess = spawned.process
                self.serverStop = spawned.stop
            }
            // If the scrcpy server (or the adb shell carrying it) ends, the
            // stream cannot recover on its own. Fail the run so the app can
            // reconnect instead of showing a frozen frame or a spinner.
            spawned.process.terminationHandler = { [weak self] process in
                guard let self, self.isActive(run) else { return }
                let status = process.terminationStatus
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.isActive(run) else { return }
                    let log = self.lastServerLog()
                    let detail = "The scrcpy server on the device stopped (exit \(status))."
                    let message = log.isEmpty ? detail : "\(detail)\n\n\(log)"
                    self.teardown(phase: .failed(message), reason: message)
                }
            }

            guard isActive(run) else {
                spawned.stop()
                listener.close()
                await adb.removeReverse(port: port, serial: device.serial)
                await adb.killServer(scid: newScid, serial: device.serial)
                return
            }

            let sockets = try await acceptSockets(listener: listener, run: run)
            guard isActive(run) else {
                SocketIO.shutdown(sockets.video)
                SocketIO.shutdown(sockets.control)
                return
            }
            guard sockets.codec == .h264 else {
                SocketIO.shutdown(sockets.video)
                SocketIO.shutdown(sockets.control)
                throw ADBError("This build supports H.264 mirroring only, but the device selected \(sockets.codec.rawValue.uppercased()).")
            }

            withStateLock {
                self.videoFD = sockets.video
                self.controlFD = sockets.control
            }

            guard isActive(run) else {
                SocketIO.shutdown(sockets.video)
                SocketIO.shutdown(sockets.control)
                spawned.stop()
                listener.close()
                await adb.removeReverse(port: port, serial: device.serial)
                await adb.killServer(scid: newScid, serial: device.serial)
                return
            }

            decoder.reset()
            decoder.onFrameDecoded = { [weak self] in
                self?.recordFrame()
            }
            decoder.onSizeChanged = { [weak self] size in
                self?.handleVideoSize(size, run: run)
            }
            decoder.onNeedsKeyframe = { [weak self] in
                self?.requestKeyframe()
            }
            decoder.onError = { [weak self] message in
                guard let self else { return }
                self.stateLock.lock()
                self.serverLog.append("\n\(message)")
                self.stateLock.unlock()
            }

            startControlReader(fd: sockets.control, run: run)
            startVideoReader(fd: sockets.video, run: run)
        } catch {
            guard isActive(run) else { return }
            let detail = error.localizedDescription
            let log = lastServerLog()
            let message = log.isEmpty ? detail : "\(detail)\n\n\(log)"
            teardown(phase: .failed(message), reason: message)
        }
    }

    private func acceptSockets(
        listener: LoopbackTCPServer,
        run: UUID
    ) async throws -> (video: Int32, control: Int32, codec: ScrcpyVideoCodec) {
        try await withCheckedThrowingContinuation { continuation in
            startQueue.async {
                var video: Int32 = -1
                var control: Int32 = -1
                do {
                    video = try listener.accept(timeout: 20)
                    SocketIO.configureStream(video)
                    control = try listener.accept(timeout: 20)
                    SocketIO.configureStream(control)

                    SocketIO.setReadTimeout(video, seconds: 12)
                    let codec = try ScrcpyStreamReader.readCodec(fd: video)
                    SocketIO.setReadTimeout(video, seconds: 10)
                    continuation.resume(returning: (video, control, codec))
                } catch {
                    if video >= 0 { SocketIO.shutdown(video) }
                    if control >= 0 { SocketIO.shutdown(control) }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func serverCommand(scid: UInt32) -> String {
        let command = ScrcpyCommand.serverCommand(scid: scid, configuration: configuration)
        #if DEBUG
        print("[session] server command length=\(command.utf8.count) (\(ScrcpyServer.version))")
        if command.utf8.count >= 256 {
            print("[session] WARNING: command line is over Samsung's safe 255-byte limit")
        }
        #endif
        return command
    }

    // MARK: - Readers

    private func startVideoReader(fd: Int32, run: UUID) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            let reader = ScrcpyStreamReader(fd: fd)
            var receivedFirstPacket = false
            while self.isActive(run) {
                do {
                    let packet = try reader.readNext()
                    if !receivedFirstPacket {
                        receivedFirstPacket = true
                        SocketIO.setReadTimeout(fd, seconds: nil)
                    }
                    switch packet {
                    case .session(let session):
                        #if DEBUG
                        print("[session] video \(session.width)x\(session.height)")
                        #endif
                        self.updateGeometry(width: session.width, height: session.height, run: run)
                        self.decoder.handleSession(width: session.width, height: session.height)
                        self.markLive(run: run)
                    case .media(let media):
                        self.recordBytes(media.payload.count + 12)
                        if media.isConfig {
                            #if DEBUG
                            print("[session …\(self.device.serial.suffix(8))] config packet \(media.payload.count) bytes")
                            #endif
                            self.decoder.handleConfig(media.payload)
                        } else {
                            #if DEBUG
                            self.mediaPacketCount += 1
                            if self.mediaPacketCount <= 3 || self.mediaPacketCount % 120 == 0 {
                                print("[session …\(self.device.serial.suffix(8))] media #\(self.mediaPacketCount) key=\(media.isKeyFrame) size=\(media.payload.count)")
                            }
                            #endif
                            self.decoder.handleFrame(
                                media.payload,
                                pts: media.pts,
                                isKeyFrame: media.isKeyFrame
                            )
                        }
                    }
                } catch {
                    if self.isActive(run) {
                        let errorText = error.localizedDescription
                        let log = self.lastServerLog()
                        let message = log.isEmpty ? errorText : "\(errorText)\n\n\(log)"
                        self.teardown(phase: .failed(message), reason: message)
                    }
                    return
                }
            }
        }
    }

    private func startControlReader(fd: Int32, run: UUID) {
        controlReadQueue.async { [weak self] in
            guard let self else { return }
            while self.isActive(run) {
                do {
                    let message = try ScrcpyDeviceMessageReader.readNext(fd: fd)
                    switch message {
                    case .clipboard(let text):
                        #if DEBUG
                        print("[clipboard] received \(text.count) chars from \(self.device.serial)")
                        #endif
                        DispatchQueue.main.async { [weak self] in
                            self?.onClipboardText?(text)
                        }
                    case .clipboardAck:
                        break
                    case .uhidOutput:
                        break
                    }
                } catch {
                    // The control channel ending normally accompanies video
                    // teardown. The video reader owns the error surface.
                    return
                }
            }
        }
    }

    private func markLive(run: UUID) {
        DispatchQueue.main.async {
            guard self.isActive(run) else { return }
            if self.phase != .live {
                self.noteVideoActivity()
                self.probeSentAt = nil
                self.phase = .live
                self.transportError = nil
                self.startStatsTimer(run: run)
                #if DEBUG
                print("[session] live \(self.device.serial) \(Int(self.videoSize.width))x\(Int(self.videoSize.height))")
                #endif
                self.refreshScreenState(after: 0.5)
                self.onLive?()
            }
        }
    }

    private func handleVideoSize(_ size: CGSize, run: UUID) {
        DispatchQueue.main.async {
            guard self.isActive(run) else { return }
            self.videoSize = size
        }
    }

    private func updateGeometry(width: Int, height: Int, run _: UUID) {
        geometryLock.lock()
        streamSize = CGSize(width: width, height: height)
        geometryLock.unlock()
    }

    // MARK: - Statistics

    private func recordFrame() {
        counterLock.lock()
        frameCounter += 1
        frameTotal += 1
        counterLock.unlock()
    }

    private func recordBytes(_ count: Int) {
        counterLock.lock()
        byteCounter += count
        lastPacketAt = Date()
        counterLock.unlock()
    }

    private func noteVideoActivity() {
        counterLock.lock()
        lastPacketAt = Date()
        counterLock.unlock()
    }

    private func secondsSinceLastPacket() -> TimeInterval {
        counterLock.lock()
        let last = lastPacketAt
        counterLock.unlock()
        return Date().timeIntervalSince(last)
    }

    /// Asks the device for a new encoder config + IDR frame, at most once
    /// every 1.5 s. Safe to call from any thread.
    public func requestKeyframe() {
        stateLock.lock()
        let now = Date()
        let allowed = now.timeIntervalSince(lastKeyframeRequest) > 1.5
        if allowed { lastKeyframeRequest = now }
        stateLock.unlock()
        guard allowed else { return }
        sendControl(ScrcpyControlMessage.resetVideo())
    }

    // MARK: - Watchdog

    /// Runs once a second on the main thread while live. scrcpy sends nothing
    /// while the picture is static, so silence alone is not a failure. After a
    /// quiet spell the session asks for a keyframe; a healthy stream answers
    /// within a second. If it does not, ADB is asked whether the phone screen
    /// is simply off. A device that does not answer, or that is awake but
    /// still silent, has a dead stream and the run is failed so it reconnects.
    private func checkHealth(run: UUID) {
        guard isActive(run), phase.isLive else { return }
        let silence = secondsSinceLastPacket()
        let now = Date()

        if let sent = probeSentAt {
            if silence < now.timeIntervalSince(sent) {
                probeSentAt = nil
                return
            }
            guard now.timeIntervalSince(sent) >= Self.probeTimeout, !livenessCheckInFlight else { return }
            livenessCheckInFlight = true
            let adb = self.adb
            let serial = device.serial
            Task { [weak self] in
                let state = await adb.screenState(serial: serial)
                await MainActor.run {
                    self?.finishLivenessCheck(state, run: run)
                }
            }
            return
        }

        if !screenPollInFlight, now.timeIntervalSince(lastScreenCheck) >= Self.screenPollInterval {
            pollScreenState(run: run)
        }
        guard silence >= Self.silenceBeforeProbe else { return }
        if screenOn == false, now.timeIntervalSince(lastScreenCheck) < 30 {
            return
        }
        probeSentAt = now
        sendControl(ScrcpyControlMessage.resetVideo())
        #if DEBUG
        print("[watchdog …\(device.serial.suffix(8))] \(Int(silence))s quiet, probing with a keyframe request")
        #endif
    }

    /// Checks the stream right away, e.g. after the Mac wakes from sleep:
    /// asks for a keyframe and reconnects if nothing comes back.
    public func probeNow() {
        guard phase.isLive, probeSentAt == nil, !livenessCheckInFlight else { return }
        probeSentAt = Date()
        lastScreenCheck = .distantPast
        sendControl(ScrcpyControlMessage.resetVideo())
    }

    private func finishLivenessCheck(_ state: ADBClient.ScreenState?, run: UUID) {
        livenessCheckInFlight = false
        guard isActive(run) else { return }
        // The stream answered while ADB was being asked.
        if let sent = probeSentAt, secondsSinceLastPacket() < Date().timeIntervalSince(sent) {
            probeSentAt = nil
            return
        }
        probeSentAt = nil
        lastScreenCheck = Date()
        #if DEBUG
        print("[watchdog …\(device.serial.suffix(8))] probe unanswered, screen=\(String(describing: state))")
        #endif
        switch state {
        case .asleep, .unknown:
            // Nothing is drawn while the screen is off; keep the session.
            screenOn = false
        case .awake:
            let message = "The video stream stopped responding. Reconnecting…"
            teardown(phase: .failed(message), reason: message)
        case nil:
            let message = "The device stopped responding over ADB. Reconnecting…"
            teardown(phase: .failed(message), reason: message)
        }
    }

    private func pollScreenState(run: UUID) {
        screenPollInFlight = true
        let adb = self.adb
        let serial = device.serial
        Task { [weak self] in
            let state = await adb.screenState(serial: serial)
            await MainActor.run {
                guard let self else { return }
                self.screenPollInFlight = false
                self.lastScreenCheck = Date()
                guard self.isActive(run), self.phase.isLive else { return }
                switch state {
                case .awake:
                    self.screenPollFailures = 0
                    if self.screenOn != true { self.screenOn = true }
                case .asleep:
                    self.screenPollFailures = 0
                    if self.screenOn != false { self.screenOn = false }
                case .unknown:
                    self.screenPollFailures = 0
                case nil:
                    // Two unanswered polls in a row: the ADB link is gone.
                    self.screenPollFailures += 1
                    if self.screenPollFailures >= 2 {
                        self.screenPollFailures = 0
                        let message = "The device stopped responding over ADB. Reconnecting…"
                        self.teardown(phase: .failed(message), reason: message)
                    }
                }
            }
        }
    }

    private func refreshScreenState(after delay: TimeInterval) {
        let adb = self.adb
        let serial = device.serial
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let state = await adb.screenState(serial: serial) else { return }
            await MainActor.run {
                guard let self, self.phase.isLive else { return }
                self.lastScreenCheck = Date()
                switch state {
                case .awake: self.screenOn = true
                case .asleep: self.screenOn = false
                case .unknown: break
                }
            }
        }
    }

    private func resetCounters() {
        counterLock.lock()
        frameCounter = 0
        byteCounter = 0
        frameTotal = 0
        counterLock.unlock()
        DispatchQueue.main.async {
            self.totalFrames = 0
        }
    }

    private func startStatsTimer(run: UUID) {
        statsTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.isActive(run) else { return }
            self.sampleStats()
            self.checkHealth(run: run)
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    private func sampleStats() {
        counterLock.lock()
        let frames = frameCounter
        let bytes = byteCounter
        frameCounter = 0
        byteCounter = 0
        counterLock.unlock()

        fps = Double(frames)
        bitrateMbps = Double(bytes * 8) / 1_000_000
        counterLock.lock()
        let total = frameTotal
        counterLock.unlock()
        totalFrames = total
        #if DEBUG
        print("[stats …\(device.serial.suffix(8))] fps=\(Int(fps)) \(decoder.debugStatus())")
        #endif
    }

    // MARK: - Input

    public func press(_ keycode: UInt32, metaState: UInt32 = 0) {
        sendControl(ScrcpyControlMessage.keycode(action: .down, keycode: keycode, metaState: metaState))
        sendControl(ScrcpyControlMessage.keycode(action: .up, keycode: keycode, metaState: metaState))
    }

    public func pressBack() {
        sendControl(ScrcpyControlMessage.backOrScreenOn(action: .down))
        sendControl(ScrcpyControlMessage.backOrScreenOn(action: .up))
    }

    /// A session can briefly have two surfaces during a single <-> wall
    /// transition: the replacement view is mounted before the old one is
    /// removed. Track tokens so the old view's detach cannot turn decoding off
    /// while the replacement surface is still on screen.
    public func displayWillAttach(token: UUID) {
        let hadSurface = !displayAttachmentTokens.isEmpty
        let isReattach = hasDisplayBeenAttached
        displayAttachmentTokens.insert(token)
        hasDisplayBeenAttached = true
        decoder.setDisplayAttached(true)
        #if DEBUG
        print("[display] attach …\(device.serial.suffix(8)) surfaces=\(displayAttachmentTokens.count)")
        #endif
        // A newly mounted surface during a live hand-off must not force an
        // encoder reset; the existing decoder/layer is still producing frames.
        // Only a genuine return from no surface needs a fresh keyframe.
        if !hadSurface, isReattach, phase.isLive {
            sendControl(ScrcpyControlMessage.resetVideo())
        }
    }

    /// The surface left the window. Keep the session alive for fast switching,
    /// but stop decoding only when the last visible surface is gone.
    public func displayDidDetach(token: UUID) {
        displayAttachmentTokens.remove(token)
        #if DEBUG
        print("[display] detach …\(device.serial.suffix(8)) surfaces=\(displayAttachmentTokens.count)")
        #endif
        if displayAttachmentTokens.isEmpty {
            decoder.setDisplayAttached(false)
        }
    }

    /// A native window transition can leave a video layer composited against
    /// stale window state even though frames are still being decoded. Flush the
    /// layer and ask scrcpy for a new IDR/config so fullscreen resumes cleanly.
    public func refreshDisplaySurface() {
        let now = Date()
        guard now.timeIntervalSince(lastDisplayRefresh) > 0.8 else { return }
        lastDisplayRefresh = now
        decoder.flushForDisplayRefresh()
        if phase.isLive {
            sendControl(ScrcpyControlMessage.resetVideo())
        }
        #if DEBUG
        print("[display] refresh surface …\(device.serial.suffix(8))")
        #endif
    }

    public func pressHome() { press(AndroidKey.home) }
    public func pressAppSwitch() { press(AndroidKey.appSwitch) }
    public func pressPower() { press(AndroidKey.power) }
    public func pressVolumeUp() { press(AndroidKey.volumeUp) }
    public func pressVolumeDown() { press(AndroidKey.volumeDown) }
    public func rotate() { sendControl(ScrcpyControlMessage.rotateDevice()) }
    public func expandNotifications() { sendControl(ScrcpyControlMessage.expandNotificationPanel()) }
    public func collapsePanels() { sendControl(ScrcpyControlMessage.collapsePanels()) }

    public func setDisplayPower(on: Bool) {
        sendControl(ScrcpyControlMessage.setDisplayPower(on: on))
    }

    /// Turns the phone's screen on (wake) or off (sleep), like its own
    /// power button but without toggling ambiguity.
    public func setScreen(on: Bool) {
        press(on ? AndroidKey.wakeUp : AndroidKey.sleep)
        screenOn = on
        if on {
            // Ask for a fresh picture as soon as the panel is back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.requestKeyframe()
            }
        }
        refreshScreenState(after: 1.2)
    }

    public func toggleScreen() {
        setScreen(on: screenOn == false)
    }

    public func sendText(_ text: String) {
        for packet in ScrcpyControlMessage.text(text) {
            sendControl(packet)
        }
    }

    public func paste(_ text: String) {
        sendText(text)
    }

    /// Pushes text into the device clipboard (without triggering a paste).
    public func setClipboard(_ text: String) {
        let capped = Self.truncatedUTF8(text, maxBytes: 200_000)
        guard !capped.isEmpty else { return }
        sendControl(
            ScrcpyControlMessage.setClipboard(
                text: capped,
                paste: false,
                sequence: 0
            )
        )
        #if DEBUG
        print("[clipboard] sent \(capped.count) chars to \(device.serial)")
        #endif
    }

    private static func truncatedUTF8(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var result = String()
        result.reserveCapacity(maxBytes)
        var used = 0
        for scalar in text.unicodeScalars {
            let scalarString = String(scalar)
            let bytes = scalarString.utf8.count
            if used + bytes > maxBytes { break }
            result.append(scalarString)
            used += bytes
        }
        return result
    }

    public func tap(x: Int, y: Int) {
        guard let geometry = currentGeometry() else { return }
        sendControl(
            ScrcpyControlMessage.touch(
                action: .down,
                x: x,
                y: y,
                screenWidth: geometry.width,
                screenHeight: geometry.height,
                pressure: 1,
                actionButton: AndroidButton.primary,
                buttons: AndroidButton.primary
            )
        )
        controlWriteQueue.asyncAfter(deadline: .now() + 0.045) { [weak self] in
            self?.sendTouchUp(x: x, y: y, geometry: geometry)
        }
    }

    public func touchDown(x: Int, y: Int) {
        guard let geometry = currentGeometry() else { return }
        sendControl(
            ScrcpyControlMessage.touch(
                action: .down,
                x: x,
                y: y,
                screenWidth: geometry.width,
                screenHeight: geometry.height,
                pressure: 1,
                actionButton: AndroidButton.primary,
                buttons: AndroidButton.primary
            )
        )
    }

    public func touchMove(x: Int, y: Int) {
        guard let geometry = currentGeometry() else { return }
        sendControl(
            ScrcpyControlMessage.touch(
                action: .move,
                x: x,
                y: y,
                screenWidth: geometry.width,
                screenHeight: geometry.height,
                pressure: 1,
                actionButton: AndroidButton.primary,
                buttons: AndroidButton.primary
            )
        )
    }

    public func touchUp(x: Int, y: Int) {
        guard let geometry = currentGeometry() else { return }
        sendTouchUp(x: x, y: y, geometry: geometry)
    }

    private func sendTouchUp(x: Int, y: Int, geometry: (width: Int, height: Int)) {
        sendControl(
            ScrcpyControlMessage.touch(
                action: .up,
                x: x,
                y: y,
                screenWidth: geometry.width,
                screenHeight: geometry.height,
                pressure: 0,
                actionButton: 0,
                buttons: 0
            )
        )
    }

    public func scroll(x: Int, y: Int, horizontal: Float, vertical: Float) {
        guard let geometry = currentGeometry() else { return }
        sendControl(
            ScrcpyControlMessage.scroll(
                x: x,
                y: y,
                screenWidth: geometry.width,
                screenHeight: geometry.height,
                horizontal: horizontal,
                vertical: vertical,
                buttons: 0
            )
        )
    }

    public func mouseClick(x: Int, y: Int) {
        tap(x: x, y: y)
    }

    private func currentGeometry() -> (width: Int, height: Int)? {
        geometryLock.lock()
        let size = streamSize
        geometryLock.unlock()
        guard size.width >= 1, size.height >= 1 else { return nil }
        return (Int(size.width), Int(size.height))
    }

    private func sendControl(_ data: Data) {
        stateLock.lock()
        let fd = controlFD
        let active = !stopped
        stateLock.unlock()
        guard active, fd >= 0 else { return }
        controlWriteQueue.async {
            do {
                try SocketIO.writeAll(fd: fd, data: data)
            } catch {
                // A closed control socket is handled by the reader and teardown.
            }
        }
    }

    // MARK: - Helpers

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private func isActive(_ run: UUID) -> Bool {
        withStateLock { !stopped && currentRun == run }
    }

    private func appendServerLog(_ chunk: String) {
        stateLock.lock()
        serverLog.append(chunk)
        if serverLog.count > 16_000 {
            serverLog = String(serverLog.suffix(12_000))
        }
        stateLock.unlock()
    }

    private func lastServerLog() -> String {
        stateLock.lock()
        let log = serverLog
        stateLock.unlock()
        let lines = log.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.suffix(4).joined(separator: "\n")
    }
}
