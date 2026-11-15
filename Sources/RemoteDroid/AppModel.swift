import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import RemoteDroidCore

@MainActor
final class AppModel: ObservableObject {
    enum LayoutMode: String, CaseIterable, Identifiable {
        case single
        case grid
        var id: String { rawValue }
    }

    enum TransferKind: String {
        case push
        case install
    }

    enum TransferState: Equatable {
        case queued
        case running
        case completed
        case failed(String)

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }

        var isCompleted: Bool { self == .completed }
    }

    struct TransferItem: Identifiable, Equatable {
        let id = UUID()
        let fileName: String
        let serial: String
        let kind: TransferKind
        /// Set when one drop installs the same APK on several devices.
        var batch: UUID? = nil
        var progress: Double
        var state: TransferState
        var detail: String
    }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String?
        let isError: Bool
    }

    @Published var devices: [AndroidDevice] = []
    @Published var selectedSerial: String?
    @Published var sessions: [String: ScrcpySession] = [:]
    @Published var layoutMode: LayoutMode = .single {
        didSet { defaults.set(layoutMode.rawValue, forKey: Keys.layoutMode) }
    }
    @Published var showInspector = true {
        didSet { defaults.set(showInspector, forKey: Keys.showInspector) }
    }
    @Published var configuration: StreamConfiguration = .balanced {
        didSet { saveConfiguration() }
    }
    @Published var isRefreshing = false
    @Published var transfers: [TransferItem] = []
    @Published var toast: Toast?
    @Published var showSettings = false
    @Published var lastRefresh: Date?
    @Published var adbProblem: String?
    @Published var autoConnectOnLaunch = true {
        didSet { defaults.set(autoConnectOnLaunch, forKey: Keys.autoConnect) }
    }
    @Published var installAPKsOnDrop = true {
        didSet { defaults.set(installAPKsOnDrop, forKey: Keys.installOnDrop) }
    }
    /// Shares plain-text clipboard content between the Mac and every live
    /// device. Defaults on; it can be disabled for privacy.
    @Published var clipboardSyncEnabled = true {
        didSet {
            defaults.set(clipboardSyncEnabled, forKey: Keys.clipboardSync)
            guard clipboardSyncEnabled else { return }
            lastPasteboardChangeCount = NSPasteboard.general.changeCount
            if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                lastSyncedClipboard = text
                broadcastClipboard(text)
            }
        }
    }
    /// Device serials selected for the side-by-side Device Wall.
    @Published var wallSerials: Set<String> = []
    /// Explicit left-to-right wall order. It may contain a selected serial
    /// while that device is temporarily disconnected.
    @Published var wallOrder: [String] = []
    @Published var showWallPicker = false

    private let defaults = UserDefaults.standard
    private var adb: ADBClient?
    private var adbVersion: String?
    private var monitorTask: Task<Void, Never>?
    /// One worker per device, so a wall-wide install runs on every phone at once
    /// while each phone still handles its own files one after another.
    private var transferWorkers: [String: Task<Void, Never>] = [:]
    private var pendingTransfers: [(url: URL, item: TransferItem)] = []
    private struct InstallBatch {
        let fileName: String
        var pending: Int
        var installed: [String] = []
        var failed: [String] = []
    }
    private var installBatches: [UUID: InstallBatch] = [:]
    private var toastDismissTask: Task<Void, Never>?
    private var lastDetailRefresh: [String: Date] = [:]
    private var didInitialAutoConnect = false
    private var didRestoreGrid = false
    private var hasStoredWallSelection = false
    private var storedADBPath: String?
    private var clipboardTimer: Timer?
    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount
    private var lastSyncedClipboard: String?
    private var recentClipboardWrites: [String: (text: String, at: Date)] = [:]
    /// Automatic reconnect bookkeeping for streams that dropped.
    private var reconnectState: [String: (attempts: Int, next: Date)] = [:]
    /// Streams the user closed on purpose; these are not reconnected.
    private var userClosedSerials: Set<String> = []
    #if DEBUG
    private var didStartDebugGrid = false
    #endif

    private enum Keys {
        static let adbPath = "adb.path"
        static let selectedSerial = "device.selectedSerial"
        static let layoutMode = "ui.layoutMode"
        static let showInspector = "ui.showInspector"
        static let autoConnect = "device.autoConnect"
        static let installOnDrop = "files.installAPKsOnDrop"
        static let maxSize = "stream.maxSize"
        static let maxFPS = "stream.maxFPS"
        static let bitRate = "stream.bitRate"
        static let keepAwake = "stream.keepAwake"
        static let wallSerials = "wall.serials"
        static let wallOrder = "wall.order"
        static let clipboardSync = "clipboard.sync"
    }

    init() {
        let savedMaxSize = defaults.object(forKey: Keys.maxSize) as? Int
        let savedFPS = defaults.object(forKey: Keys.maxFPS) as? Int
        let savedBitRate = defaults.object(forKey: Keys.bitRate) as? Int
        let savedKeepAwake = defaults.object(forKey: Keys.keepAwake) as? Bool
        configuration = StreamConfiguration(
            maxSize: savedMaxSize ?? 1920,
            maxFPS: savedFPS ?? 60,
            bitRate: savedBitRate ?? 24_000_000,
            keepAwake: savedKeepAwake ?? true
        )
        layoutMode = LayoutMode(rawValue: defaults.string(forKey: Keys.layoutMode) ?? "") ?? .single
        showInspector = defaults.object(forKey: Keys.showInspector) as? Bool ?? true
        autoConnectOnLaunch = defaults.object(forKey: Keys.autoConnect) as? Bool ?? true
        installAPKsOnDrop = defaults.object(forKey: Keys.installOnDrop) as? Bool ?? true
        clipboardSyncEnabled = defaults.object(forKey: Keys.clipboardSync) as? Bool ?? true
        selectedSerial = defaults.string(forKey: Keys.selectedSerial)
        lastSyncedClipboard = NSPasteboard.general.string(forType: .string)
        lastPasteboardChangeCount = NSPasteboard.general.changeCount
        if let storedWall = defaults.array(forKey: Keys.wallSerials) as? [String] {
            wallSerials = Set(storedWall)
            hasStoredWallSelection = true
        }
        if let storedOrder = defaults.array(forKey: Keys.wallOrder) as? [String] {
            wallOrder = storedOrder
        }
        storedADBPath = defaults.string(forKey: Keys.adbPath)
        resolveADB()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stopAll()
            }
        }
        // After the Mac sleeps, locks or switches user, USB/ADB links and
        // the video layers may be stale. Check every stream right away.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self?.sessions.values.forEach { $0.probeNow() }
                    self?.refreshNow()
                }
            }
        }
    }

    // MARK: - Derived state

    var selectedDevice: AndroidDevice? {
        guard let selectedSerial else { return nil }
        return devices.first { $0.serial == selectedSerial }
    }

    var activeSession: ScrcpySession? {
        guard let selectedSerial else { return nil }
        return sessions[selectedSerial]
    }

    var readyDevices: [AndroidDevice] {
        devices.filter(\.isReady)
    }

    /// The devices explicitly chosen for the wall, in the user's saved
    /// left-to-right order. Selected devices missing from the order (for
    /// example after a fresh selection) fall back to ADB order at the end.
    var wallDevices: [AndroidDevice] {
        let readyBySerial = Dictionary(
            uniqueKeysWithValues: devices.filter(\.isReady).map { ($0.serial, $0) }
        )
        var result: [AndroidDevice] = []
        var seen: Set<String> = []
        for serial in wallOrder where wallSerials.contains(serial) {
            guard let device = readyBySerial[serial], seen.insert(serial).inserted else { continue }
            result.append(device)
        }
        for device in devices where device.isReady && wallSerials.contains(device.serial) {
            if seen.insert(device.serial).inserted {
                result.append(device)
            }
        }
        return result
    }

    var connectedSessionCount: Int {
        sessions.values.filter { $0.phase.isLive || $0.phase == .connecting }.count
    }

    var adbDisplayVersion: String? {
        guard let adbVersion else { return nil }
        if let range = adbVersion.range(of: "version ", options: .caseInsensitive) {
            return String(adbVersion[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return adbVersion
    }

    var adbPathDisplay: String {
        guard let adb else { return "ADB not found" }
        return abbreviatePath(adb.executableURL.path)
    }

    func device(for serial: String) -> AndroidDevice? {
        devices.first { $0.serial == serial }
    }

    func session(for serial: String) -> ScrcpySession? {
        sessions[serial]
    }

    func isSessionLive(_ serial: String) -> Bool {
        sessions[serial]?.phase.isLive == true
    }

    // MARK: - Monitoring

    func startMonitoring() {
        guard monitorTask == nil else { return }
        startClipboardMonitor()
        monitorTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh(showSpinner: false)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                await self.refresh(showSpinner: false)
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        clipboardTimer?.invalidate()
        clipboardTimer = nil
    }

    func refreshNow() {
        Task { await refresh(showSpinner: true) }
    }

    private func refresh(showSpinner: Bool) async {
        if showSpinner { isRefreshing = true }
        defer { if showSpinner { isRefreshing = false } }

        if adb == nil {
            resolveADB()
        }
        guard let adb else {
            devices = []
            adbProblem = "ADB was not found. Locate the platform-tools executable to discover phones and emulators."
            return
        }
        adbProblem = nil

        do {
            var latest = try await adb.listDevices()
            let currentBySerial = Dictionary(uniqueKeysWithValues: devices.map { ($0.serial, $0) })
            let now = Date()
            var needsDetails: [String] = []
            for index in latest.indices {
                let serial = latest[index].serial
                if let existing = currentBySerial[serial] {
                    latest[index].details = existing.details
                }
                guard latest[index].isReady else { continue }
                let last = lastDetailRefresh[serial] ?? .distantPast
                if latest[index].details == nil || now.timeIntervalSince(last) > 20 {
                    needsDetails.append(serial)
                }
            }

            if !needsDetails.isEmpty {
                let requested = needsDetails
                var loaded: [String: DeviceDetails] = [:]
                await withTaskGroup(of: (String, DeviceDetails?).self) { group in
                    for serial in requested {
                        group.addTask {
                            (serial, await adb.loadDetails(for: serial))
                        }
                    }
                    for await (serial, details) in group {
                        if let details { loaded[serial] = details }
                    }
                }
                for index in latest.indices {
                    if let details = loaded[latest[index].serial] {
                        latest[index].details = details
                        lastDetailRefresh[latest[index].serial] = now
                    }
                }
            }

            let previousSerials = Set(devices.map(\.serial))
            let latestSerials = Set(latest.map(\.serial))
            devices = latest
            lastRefresh = now

            if !hasStoredWallSelection, !readyDevices.isEmpty {
                wallSerials = Set(readyDevices.map(\.serial))
                hasStoredWallSelection = true
                persistWallSelection()
            }

            // Drop sessions for devices that disappeared or lost authorization.
            for (serial, session) in sessions {
                if !latestSerials.contains(serial) || latest.first(where: { $0.serial == serial })?.isReady != true {
                    session.stop()
                    sessions.removeValue(forKey: serial)
                }
            }

            for serial in previousSerials.subtracting(latestSerials) {
                lastDetailRefresh.removeValue(forKey: serial)
            }

            handleSelectionChange()
            recoverSessions()
            if layoutMode == .grid, !didRestoreGrid, !readyDevices.isEmpty {
                didRestoreGrid = true
                ensureWallSessions()
            }
            if layoutMode == .grid {
                selectActiveWallDeviceIfNeeded()
            }
            #if DEBUG
            if !didStartDebugGrid, ProcessInfo.processInfo.environment["UU_START_GRID"] == "1" {
                didStartDebugGrid = true
                setLayout(.grid)
                ensureWallSessions()
            }
            #endif
        } catch {
            adbProblem = friendly(error)
            if devices.isEmpty {
                sessions.values.forEach { $0.stop() }
                sessions.removeAll()
            }
        }
    }

    private func handleSelectionChange() {
        if layoutMode == .grid {
            if let selectedSerial, wallDevices.contains(where: { $0.serial == selectedSerial }) {
                didInitialAutoConnect = true
                return
            }
            let next = wallDevices.first?.serial
            selectedSerial = next
            if let next {
                defaults.set(next, forKey: Keys.selectedSerial)
            } else {
                defaults.removeObject(forKey: Keys.selectedSerial)
            }
            didInitialAutoConnect = true
            return
        }

        if let selectedSerial,
           let device = devices.first(where: { $0.serial == selectedSerial }),
           device.isReady {
            if !didInitialAutoConnect, autoConnectOnLaunch, sessions[selectedSerial] == nil {
                ensureSession(for: device)
            }
            didInitialAutoConnect = true
            return
        }

        // Keep an unauthorized device selected so its authorization
        // instructions stay on screen instead of jumping to another phone.
        if let selectedSerial,
           let device = devices.first(where: { $0.serial == selectedSerial }),
           device.state == .unauthorized {
            didInitialAutoConnect = true
            return
        }

        // The selected device is gone or not usable. Move to the first usable one.
        if let first = readyDevices.first {
            let changed = selectedSerial != first.serial
            selectedSerial = first.serial
            defaults.set(first.serial, forKey: Keys.selectedSerial)
            if changed, autoConnectOnLaunch, sessions[first.serial] == nil {
                ensureSession(for: first)
            }
        } else if let selectedSerial,
                  devices.contains(where: { $0.serial == selectedSerial }) == false {
            self.selectedSerial = nil
        }
        didInitialAutoConnect = true
    }

    // MARK: - Automatic recovery

    /// Restarts streams that failed (device restarted scrcpy, USB hiccup,
    /// adb server restart, Mac sleep) with a short backoff, and recreates wall
    /// streams that were dropped while a device was briefly offline.
    private func recoverSessions() {
        let now = Date()
        for (serial, session) in sessions {
            guard let device = device(for: serial), device.isReady else { continue }
            switch session.phase {
            case .live:
                reconnectState[serial] = nil
            case .failed:
                guard var state = reconnectState[serial] else {
                    reconnectState[serial] = (0, now.addingTimeInterval(2))
                    continue
                }
                guard now >= state.next else { continue }
                state.attempts += 1
                let delay = min(30, 3 * pow(2, Double(min(state.attempts, 4))))
                state.next = now.addingTimeInterval(delay)
                reconnectState[serial] = state
                #if DEBUG
                print("[recover] reconnecting \(serial) attempt \(state.attempts)")
                #endif
                restartSession(serial: serial, device: device)
            case .idle, .connecting:
                break
            }
        }
        for serial in reconnectState.keys where sessions[serial] == nil {
            reconnectState.removeValue(forKey: serial)
        }

        let wanted: [AndroidDevice]
        if layoutMode == .grid {
            wanted = wallDevices
        } else if autoConnectOnLaunch, let selected = selectedDevice {
            wanted = [selected]
        } else {
            wanted = []
        }
        for device in wanted where device.isReady
            && sessions[device.serial] == nil
            && !userClosedSerials.contains(device.serial) {
            ensureSession(for: device)
        }
    }

    private func restartSession(serial: String, device: AndroidDevice) {
        sessions[serial]?.stop()
        sessions.removeValue(forKey: serial)
        ensureSession(for: device)
    }

    // MARK: - Screen power

    func setScreen(on: Bool, serial: String) {
        sessions[serial]?.setScreen(on: on)
    }

    func toggleScreen(serial: String) {
        sessions[serial]?.toggleScreen()
    }

    /// Turns every live wall screen (or, in single mode, every live
    /// session) on or off.
    func setAllScreens(on: Bool) {
        let serials = layoutMode == .grid ? wallDevices.map(\.serial) : Array(sessions.keys)
        for serial in serials {
            guard let session = sessions[serial], session.phase.isLive else { continue }
            session.setScreen(on: on)
        }
        showToast(
            icon: on ? "sun.max.fill" : "moon.fill",
            title: on ? "Screens on" : "Screens off",
            detail: nil,
            isError: false
        )
    }

    // MARK: - Sessions

    func selectDevice(_ serial: String) {
        guard let device = devices.first(where: { $0.serial == serial }) else { return }
        selectedSerial = serial
        defaults.set(serial, forKey: Keys.selectedSerial)
        if layoutMode == .grid, device.isReady {
            wallSerials.insert(serial)
            hasStoredWallSelection = true
            persistWallSelection()
            selectActiveWallDeviceIfNeeded()
        }
        if device.isReady {
            if let existing = sessions[serial], case .failed = existing.phase {
                existing.stop()
                sessions.removeValue(forKey: serial)
            }
            ensureSession(for: device)
            if layoutMode == .grid {
                ensureWallSessions()
            }
        }
    }

    func ensureSession(for device: AndroidDevice) {
        guard device.isReady else { return }
        userClosedSerials.remove(device.serial)
        if let existing = sessions[device.serial] {
            if case .failed = existing.phase {
                return
            }
            if existing.phase == .idle {
                existing.start()
            }
            return
        }
        guard let adb else {
            showToast(icon: "exclamationmark.triangle.fill", title: "ADB not available", detail: "Locate adb in Settings first.", isError: true)
            return
        }
        let session = ScrcpySession(adb: adb, device: device, configuration: configuration)
        session.onClipboardText = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.handleDeviceClipboard(text, from: device.serial)
            }
        }
        session.onLive = { [weak self, weak session] in
            Task { @MainActor [weak self, weak session] in
                guard let self, let session else { return }
                self.pushClipboardToNewSession(session)
            }
        }
        sessions[device.serial] = session
        session.start()
    }

    func retrySession(for serial: String) {
        if let existing = sessions[serial] {
            existing.stop()
            sessions.removeValue(forKey: serial)
        }
        guard let device = device(for: serial) else { return }
        ensureSession(for: device)
    }

    func closeSession(for serial: String) {
        userClosedSerials.insert(serial)
        reconnectState.removeValue(forKey: serial)
        sessions[serial]?.stop()
        sessions.removeValue(forKey: serial)
    }

    /// Starts only the streams selected for the wall. Hidden, unselected
    /// streams are not created.
    func ensureWallSessions() {
        guard layoutMode == .grid else { return }
        for device in wallDevices where sessions[device.serial] == nil {
            ensureSession(for: device)
        }
    }

    func toggleWallDevice(_ serial: String) {
        guard let device = device(for: serial) else { return }
        if wallSerials.contains(serial) {
            wallSerials.remove(serial)
            if layoutMode == .grid, selectedSerial == serial {
                selectedSerial = wallDevices.first?.serial
                if let selectedSerial {
                    defaults.set(selectedSerial, forKey: Keys.selectedSerial)
                } else {
                    defaults.removeObject(forKey: Keys.selectedSerial)
                }
            }
        } else {
            wallSerials.insert(serial)
            if device.isReady {
                ensureSession(for: device)
                if layoutMode == .grid {
                    selectedSerial = serial
                    defaults.set(serial, forKey: Keys.selectedSerial)
                }
            }
        }
        hasStoredWallSelection = true
        persistWallSelection()
    }

    func selectAllWallDevices() {
        wallSerials = Set(readyDevices.map(\.serial))
        hasStoredWallSelection = true
        persistWallSelection()
        if layoutMode == .grid {
            ensureWallSessions()
            selectActiveWallDeviceIfNeeded()
        }
    }

    func clearWallDevices() {
        wallSerials.removeAll()
        hasStoredWallSelection = true
        persistWallSelection()
        if layoutMode == .grid {
            selectedSerial = nil
            defaults.removeObject(forKey: Keys.selectedSerial)
        }
    }

    private func normalizedWallOrder() -> [String] {
        var seen: Set<String> = []
        var ordered = wallOrder.filter { serial in
            wallSerials.contains(serial) && seen.insert(serial).inserted
        }
        for device in devices where wallSerials.contains(device.serial) {
            if seen.insert(device.serial).inserted {
                ordered.append(device.serial)
            }
        }
        return ordered
    }

    private func persistWallSelection() {
        let ordered = normalizedWallOrder()
        wallOrder = ordered
        defaults.set(Array(wallSerials), forKey: Keys.wallSerials)
        defaults.set(ordered, forKey: Keys.wallOrder)
    }

    /// Places a dragged tile in the slot currently occupied by `target`.
    func moveWallDevice(_ serial: String, toSlotOf target: String) {
        guard wallSerials.contains(serial), wallSerials.contains(target), serial != target else { return }
        let order = normalizedWallOrder()
        let next = WallOrder.moving(order, serial: serial, toSlotOf: target)
        guard next != order else { return }
        wallOrder = next
        defaults.set(next, forKey: Keys.wallOrder)
    }

    /// Precise keyboard/context-menu fallback for drag reordering.
    func moveWallDevice(_ serial: String, by offset: Int) {
        let visible = wallDevices.map(\.serial)
        guard let index = visible.firstIndex(of: serial) else { return }
        let destination = min(max(index + offset, 0), visible.count - 1)
        guard destination != index else { return }
        moveWallDevice(serial, toSlotOf: visible[destination])
    }

    private func selectActiveWallDeviceIfNeeded() {
        guard layoutMode == .grid else { return }
        if let selectedSerial, wallDevices.contains(where: { $0.serial == selectedSerial }) {
            return
        }
        selectedSerial = wallDevices.first?.serial
        if let selectedSerial {
            defaults.set(selectedSerial, forKey: Keys.selectedSerial)
        } else {
            defaults.removeObject(forKey: Keys.selectedSerial)
        }
    }

    func restartAllSessions() {
        let serials = Array(sessions.keys)
        sessions.values.forEach { $0.stop() }
        sessions.removeAll()
        for serial in serials {
            if let device = device(for: serial) {
                ensureSession(for: device)
            }
        }
    }

    func stopAll() {
        monitorTask?.cancel()
        monitorTask = nil
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        sessions.values.forEach { $0.stop() }
        sessions.removeAll()
        transferWorkers.values.forEach { $0.cancel() }
        transferWorkers.removeAll()
    }

    // MARK: - Settings

    func setLayout(_ mode: LayoutMode) {
        layoutMode = mode
        if mode == .grid {
            selectActiveWallDeviceIfNeeded()
            ensureWallSessions()
        }
    }

    func setConfiguration(_ configuration: StreamConfiguration) {
        self.configuration = configuration
        saveConfiguration()
        restartAllSessions()
    }

    func locateADB() {
        let panel = NSOpenPanel()
        panel.title = "Locate adb"
        panel.message = "Choose the adb executable from Android platform-tools."
        panel.prompt = "Use adb"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ADBClient.version(for: url) != nil else {
            showToast(icon: "xmark.octagon.fill", title: "That is not adb", detail: "Choose a valid platform-tools/adb executable.", isError: true)
            return
        }
        storedADBPath = url.path
        defaults.set(url.path, forKey: Keys.adbPath)
        resolveADB()
        devices = []
        sessions.values.forEach { $0.stop() }
        sessions.removeAll()
        showToast(icon: "checkmark.circle.fill", title: "ADB connected", detail: self.abbreviatePath(url.path), isError: false)
        Task { await refresh(showSpinner: true) }
    }

    func useAutomaticADB() {
        storedADBPath = nil
        defaults.removeObject(forKey: Keys.adbPath)
        sessions.values.forEach { $0.stop() }
        sessions.removeAll()
        devices = []
        lastDetailRefresh.removeAll()
        resolveADB()
        Task { await refresh(showSpinner: true) }
    }

    private func resolveADB() {
        guard let url = ADBClient.resolveADB(customPath: storedADBPath) else {
            adb = nil
            adbVersion = nil
            adbProblem = "ADB was not found. Locate the platform-tools executable to discover phones and emulators."
            return
        }
        adb = ADBClient(executableURL: url)
        adbVersion = ADBClient.version(for: url)
        adbProblem = nil
    }

    private func saveConfiguration() {
        defaults.set(configuration.maxSize, forKey: Keys.maxSize)
        defaults.set(configuration.maxFPS, forKey: Keys.maxFPS)
        defaults.set(configuration.bitRate, forKey: Keys.bitRate)
        defaults.set(configuration.keepAwake, forKey: Keys.keepAwake)
    }

    // MARK: - Files

    func chooseFiles(installOnly: Bool) {
        guard selectedDevice?.isReady == true else {
            showToast(icon: "iphone.slash", title: "No active device", detail: "Connect a device before sending files.", isError: true)
            return
        }
        let panel = NSOpenPanel()
        panel.title = installOnly ? "Install APK" : "Send files to device"
        panel.prompt = installOnly ? "Install" : "Send"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = !installOnly
        if installOnly {
            panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        } else {
            panel.allowsOtherFileTypes = true
        }
        guard panel.runModal() == .OK else { return }
        sendFiles(panel.urls, forceInstall: installOnly ? true : nil)
    }

    func sendFiles(_ urls: [URL], forceInstall: Bool? = nil) {
        guard let device = selectedDevice, device.isReady else {
            showToast(icon: "iphone.slash", title: "No active device", detail: "Select a connected phone or emulator first.", isError: true)
            return
        }
        guard !urls.isEmpty else { return }

        var added: [TransferItem] = []
        for url in urls {
            let isAPK = url.pathExtension.lowercased() == "apk"
            let shouldInstall = forceInstall ?? (isAPK && installAPKsOnDrop)
            let item = TransferItem(
                fileName: url.lastPathComponent,
                serial: device.serial,
                kind: shouldInstall ? .install : .push,
                progress: 0,
                state: .queued,
                detail: shouldInstall ? "Waiting to install" : "Waiting to send"
            )
            added.append(item)
        }
        transfers.append(contentsOf: added)
        trimTransfers()
        pendingTransfers.append(contentsOf: zip(urls, added).map { (url: $0.0, item: $0.1) })
        startTransferWorkerIfNeeded()
    }

    /// Installs every APK in `urls` on each device on the wall at the same time.
    /// Returns false when nothing could be installed (no APKs or no devices).
    @discardableResult
    func installOnWall(_ urls: [URL]) -> Bool {
        let apks = urls.filter { $0.pathExtension.lowercased() == "apk" }
        var targets = wallDevices
        if targets.isEmpty { targets = readyDevices }
        fileLog.notice("installOnWall apks=\(apks.count) targets=\(targets.map(\.serial).joined(separator: ","), privacy: .public)")
        guard !apks.isEmpty else { return false }
        guard !targets.isEmpty else {
            showToast(icon: "iphone.slash", title: "No devices on the wall", detail: "Connect a phone before installing.", isError: true)
            return false
        }
        var queued: [(url: URL, item: TransferItem)] = []
        for apk in apks {
            let batch = UUID()
            installBatches[batch] = InstallBatch(fileName: apk.lastPathComponent, pending: targets.count)
            for device in targets {
                let item = TransferItem(
                    fileName: apk.lastPathComponent,
                    serial: device.serial,
                    kind: .install,
                    batch: batch,
                    progress: 0,
                    state: .queued,
                    detail: "Waiting · \(device.displayName)"
                )
                queued.append((apk, item))
            }
        }
        transfers.append(contentsOf: queued.map(\.item))
        trimTransfers()
        pendingTransfers.append(contentsOf: queued)
        startTransferWorkerIfNeeded()
        let phones = targets.count == 1 ? "1 device" : "\(targets.count) devices"
        let what = apks.count == 1 ? apks[0].lastPathComponent : "\(apks.count) APKs"
        showToast(icon: "shippingbox.fill", title: "Installing \(what)", detail: "On \(phones) at once", isError: false)
        return true
    }

    /// Opens (or brings forward) the logcat window for a device.
    func openLogcat(serial: String? = nil) {
        guard let serial = serial ?? selectedSerial,
              let device = device(for: serial), device.isReady else {
            showToast(icon: "text.alignleft", title: "No active device", detail: "Select a connected device to view its log.", isError: true)
            return
        }
        guard let adb else {
            showToast(icon: "exclamationmark.triangle.fill", title: "ADB is not ready", detail: "Choose adb in Settings first.", isError: true)
            return
        }
        LogcatWindows.shared.open(serial: serial, deviceName: device.displayName, adb: adb.executableURL)
    }

    func dismissTransfer(_ id: UUID) {
        transfers.removeAll { $0.id == id }
    }

    private func startTransferWorkerIfNeeded() {
        let serials = Set(pendingTransfers.map(\.item.serial))
        for serial in serials where transferWorkers[serial] == nil {
            transferWorkers[serial] = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled,
                      let index = self.pendingTransfers.firstIndex(where: { $0.item.serial == serial }) {
                    let next = self.pendingTransfers.remove(at: index)
                    await self.performTransfer(item: next.item, url: next.url)
                }
                self.transferWorkers[serial] = nil
                if self.pendingTransfers.contains(where: { $0.item.serial == serial }) {
                    self.startTransferWorkerIfNeeded()
                }
            }
        }
    }

    /// Records one device's result for a wall-wide install and shows a single
    /// summary toast once every device has finished.
    private func finishBatchItem(_ item: TransferItem, deviceName: String, error: String?) {
        guard let id = item.batch, var batch = installBatches[id] else { return }
        batch.pending -= 1
        if error == nil { batch.installed.append(deviceName) } else { batch.failed.append(deviceName) }
        guard batch.pending <= 0 else {
            installBatches[id] = batch
            return
        }
        installBatches[id] = nil
        let total = batch.installed.count + batch.failed.count
        if batch.failed.isEmpty {
            showToast(
                icon: "checkmark.seal.fill",
                title: "\(batch.fileName) installed",
                detail: total == 1 ? batch.installed[0] : "On all \(total) devices",
                isError: false
            )
        } else {
            showToast(
                icon: "exclamationmark.triangle.fill",
                title: "Installed on \(batch.installed.count) of \(total)",
                detail: "Failed: " + batch.failed.joined(separator: ", "),
                isError: true
            )
        }
    }

    private func performTransfer(item: TransferItem, url: URL) async {
        guard let adb, let device = device(for: item.serial), device.isReady else {
            updateTransfer(item.id) {
                $0.state = .failed("Device is no longer available")
                $0.detail = "Reconnect the device and try again"
            }
            finishBatchItem(item, deviceName: device(for: item.serial)?.displayName ?? item.serial, error: "unavailable")
            return
        }
        updateTransfer(item.id) {
            $0.state = .running
            if item.kind == .install {
                $0.detail = item.batch == nil ? "Installing APK…" : "Installing · \(device.displayName)"
            } else {
                $0.detail = "Sending to Download…"
            }
            $0.progress = item.kind == .install ? 0.2 : 0
        }

        do {
            switch item.kind {
            case .install:
                fileLog.notice("install start \(item.serial, privacy: .public) \(url.lastPathComponent, privacy: .public)")
                try await adb.install(apkURL: url, serial: item.serial)
                fileLog.notice("install ok \(item.serial, privacy: .public)")
                updateTransfer(item.id) {
                    $0.state = .completed
                    $0.progress = 1
                    $0.detail = "Installed on \(device.displayName)"
                }
                if item.batch != nil {
                    finishBatchItem(item, deviceName: device.displayName, error: nil)
                } else {
                    showToast(icon: "checkmark.seal.fill", title: "\(item.fileName) installed", detail: device.displayName, isError: false)
                }
            case .push:
                try await adb.push(
                    localURL: url,
                    remoteName: url.lastPathComponent,
                    serial: item.serial
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.updateTransfer(item.id) {
                            $0.progress = progress
                            $0.detail = "Sending to Download… \(Int(progress * 100))%"
                        }
                    }
                }
                updateTransfer(item.id) {
                    $0.state = .completed
                    $0.progress = 1
                    $0.detail = "Saved to Download/\(item.fileName)"
                }
                showToast(icon: "paperplane.fill", title: "\(item.fileName) sent", detail: "Available in the device's Download folder", isError: false)
            }
        } catch {
            let message = friendly(error)
            fileLog.error("transfer failed \(item.serial, privacy: .public): \(String(describing: error), privacy: .public)")
            updateTransfer(item.id) {
                $0.state = .failed(message)
                $0.detail = item.kind == .install
                    ? (item.batch == nil ? "Install failed" : "Failed · \(device.displayName)")
                    : "Transfer failed"
            }
            if item.batch != nil {
                finishBatchItem(item, deviceName: device.displayName, error: message)
                return
            }
            showToast(
                icon: "exclamationmark.triangle.fill",
                title: item.kind == .install ? "Install failed" : "Send failed",
                detail: message,
                isError: true
            )
        }
    }

    private func updateTransfer(_ id: UUID, mutate: (inout TransferItem) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        mutate(&transfers[index])
    }

    private func trimTransfers() {
        let active = transfers.filter { !$0.state.isCompleted }
        let completed = transfers.filter { $0.state.isCompleted }.suffix(3)
        transfers = Array(active) + Array(completed)
    }

    // MARK: - Screenshot

    func captureScreenshot() {
        guard let adb, let device = selectedDevice, device.isReady else {
            showToast(icon: "camera.fill", title: "No active device", detail: "Select a connected device first.", isError: true)
            return
        }
        Task {
            do {
                let data = try await adb.screenshot(serial: device.serial)
                let panel = NSSavePanel()
                panel.title = "Save screenshot"
                panel.nameFieldStringValue = "RemoteDroid-\(safeName(device.displayName))-\(Self.fileTimestamp()).png"
                panel.allowedContentTypes = [.png]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url)
                showToast(icon: "camera.fill", title: "Screenshot saved", detail: url.lastPathComponent, isError: false)
            } catch {
                showToast(icon: "exclamationmark.triangle.fill", title: "Screenshot failed", detail: friendly(error), isError: true)
            }
        }
    }

    // MARK: - Clipboard

    /// The Mac clipboard is the hub: a copy on any device updates the Mac and
    /// every other live device, and a copy on the Mac updates every live device.
    private func startClipboardMonitor() {
        guard clipboardTimer == nil else { return }
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollHostClipboard()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clipboardTimer = timer
    }

    private func pollHostClipboard() {
        guard clipboardSyncEnabled else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            lastSyncedClipboard = nil
            return
        }
        guard text != lastSyncedClipboard else { return }
        lastSyncedClipboard = text
        broadcastClipboard(text)
    }

    private func handleDeviceClipboard(_ text: String, from serial: String) {
        guard clipboardSyncEnabled, !text.isEmpty else { return }
        // The server sends a clipboard notification for the clipboard write we
        // just requested. Those asynchronous echoes must not overwrite a newer
        // local copy from another device or the host.
        guard !isRecentClipboardWrite(text, from: serial) else { return }
        guard text != lastSyncedClipboard else { return }
        lastSyncedClipboard = text

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString(text, forType: .string)
        lastPasteboardChangeCount = pasteboard.changeCount

        broadcastClipboard(text, excluding: serial)
        if let device = device(for: serial) {
            showToast(
                icon: "doc.on.clipboard.fill",
                title: "Clipboard from \(device.displayName)",
                detail: "Mac clipboard updated",
                isError: false
            )
        }
    }

    private func broadcastClipboard(_ text: String, excluding serial: String? = nil) {
        guard clipboardSyncEnabled else { return }
        for (sessionSerial, session) in sessions
        where sessionSerial != serial && session.phase.isLive {
            session.setClipboard(text)
            noteClipboardWrite(text, to: sessionSerial)
        }
    }

    private func pushClipboardToNewSession(_ session: ScrcpySession) {
        guard clipboardSyncEnabled else { return }
        guard sessions[session.device.serial] === session else { return }
        guard let text = lastSyncedClipboard ?? NSPasteboard.general.string(forType: .string),
              !text.isEmpty else { return }
        session.setClipboard(text)
        noteClipboardWrite(text, to: session.device.serial)
    }

    private func noteClipboardWrite(_ text: String, to serial: String) {
        let cutoff = Date().addingTimeInterval(-4)
        recentClipboardWrites = recentClipboardWrites.filter { $0.value.at > cutoff }
        recentClipboardWrites[serial] = (text, Date())
    }

    private func isRecentClipboardWrite(_ text: String, from serial: String) -> Bool {
        guard let entry = recentClipboardWrites[serial] else { return false }
        return entry.text == text && Date().timeIntervalSince(entry.at) < 4
    }

    func pasteClipboard(into session: ScrcpySession) {
        guard let string = NSPasteboard.general.string(forType: .string), !string.isEmpty else {
            showToast(icon: "doc.on.clipboard", title: "Clipboard is empty", detail: nil, isError: false)
            return
        }
        session.setClipboard(string)
        noteClipboardWrite(string, to: session.device.serial)
        session.paste(string)
        showToast(icon: "doc.on.clipboard.fill", title: "Pasted to device", detail: "\(string.count) characters", isError: false)
    }

    // MARK: - Toast

    func showToast(icon: String, title: String, detail: String?, isError: Bool) {
        let toast = Toast(icon: icon, title: title, detail: detail, isError: isError)
        self.toast = toast
        toastDismissTask?.cancel()
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: isError ? 5_500_000_000 : 3_500_000_000)
            guard !Task.isCancelled else { return }
            if self?.toast?.id == toast.id {
                self?.toast = nil
            }
        }
    }

    // MARK: - Helpers

    func friendly(_ error: Error) -> String {
        if let adbError = error as? ADBError {
            let output = adbError.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if output.count > 800 {
                return String(output.prefix(800)) + "…"
            }
            return output.isEmpty ? adbError.message : output
        }
        return error.localizedDescription
    }

    func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.replacingOccurrences(of: home, with: "~")
    }

    private func safeName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "device" : trimmed
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

