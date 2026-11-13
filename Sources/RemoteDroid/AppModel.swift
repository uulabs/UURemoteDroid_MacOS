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
    @Published var isConnectingAll = false
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

    private let defaults = UserDefaults.standard
    private var adb: ADBClient?
    private var adbVersion: String?
    private var monitorTask: Task<Void, Never>?
    private var transferWorker: Task<Void, Never>?
    private var pendingTransfers: [(url: URL, item: TransferItem)] = []
    private var toastDismissTask: Task<Void, Never>?
    private var lastDetailRefresh: [String: Date] = [:]
    private var didInitialAutoConnect = false
    private var didRestoreGrid = false
    private var storedADBPath: String?
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
        selectedSerial = defaults.string(forKey: Keys.selectedSerial)
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
            if layoutMode == .grid, !didRestoreGrid, !readyDevices.isEmpty {
                didRestoreGrid = true
                ensureAllReadySessions()
            }
            #if DEBUG
            if !didStartDebugGrid, ProcessInfo.processInfo.environment["UU_START_GRID"] == "1" {
                didStartDebugGrid = true
                setLayout(.grid)
                connectAll()
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

    // MARK: - Sessions

    func selectDevice(_ serial: String) {
        guard let device = devices.first(where: { $0.serial == serial }) else { return }
        selectedSerial = serial
        defaults.set(serial, forKey: Keys.selectedSerial)
        if device.isReady {
            if let existing = sessions[serial], case .failed = existing.phase {
                existing.stop()
                sessions.removeValue(forKey: serial)
            }
            ensureSession(for: device)
            if layoutMode == .grid {
                ensureAllReadySessions()
            }
        }
    }

    func ensureSession(for device: AndroidDevice) {
        guard device.isReady else { return }
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
        sessions[serial]?.stop()
        sessions.removeValue(forKey: serial)
    }

    func connectAll() {
        guard !isConnectingAll else { return }
        isConnectingAll = true
        let ready = readyDevices
        Task {
            for (index, device) in ready.enumerated() {
                ensureSession(for: device)
                if index < ready.count - 1 {
                    try? await Task.sleep(nanoseconds: 180_000_000)
                }
            }
            isConnectingAll = false
        }
    }

    func ensureAllReadySessions() {
        for device in readyDevices where sessions[device.serial] == nil {
            ensureSession(for: device)
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
        sessions.values.forEach { $0.stop() }
        sessions.removeAll()
        transferWorker?.cancel()
        transferWorker = nil
    }

    // MARK: - Settings

    func setLayout(_ mode: LayoutMode) {
        layoutMode = mode
        if mode == .grid {
            ensureAllReadySessions()
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

    func dismissTransfer(_ id: UUID) {
        transfers.removeAll { $0.id == id }
    }

    private func startTransferWorkerIfNeeded() {
        guard transferWorker == nil, !pendingTransfers.isEmpty else { return }
        transferWorker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !self.pendingTransfers.isEmpty {
                let next = self.pendingTransfers.removeFirst()
                await self.performTransfer(item: next.item, url: next.url)
            }
            self.transferWorker = nil
            if !self.pendingTransfers.isEmpty {
                self.startTransferWorkerIfNeeded()
            }
        }
    }

    private func performTransfer(item: TransferItem, url: URL) async {
        guard let adb, let device = device(for: item.serial), device.isReady else {
            updateTransfer(item.id) {
                $0.state = .failed("Device is no longer available")
                $0.detail = "Reconnect the device and try again"
            }
            return
        }
        updateTransfer(item.id) {
            $0.state = .running
            $0.detail = item.kind == .install ? "Installing APK…" : "Sending to Download…"
            $0.progress = item.kind == .install ? 0.2 : 0
        }

        do {
            switch item.kind {
            case .install:
                try await adb.install(apkURL: url, serial: item.serial)
                updateTransfer(item.id) {
                    $0.state = .completed
                    $0.progress = 1
                    $0.detail = "Installed on \(device.displayName)"
                }
                showToast(icon: "checkmark.seal.fill", title: "\(item.fileName) installed", detail: device.displayName, isError: false)
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
            updateTransfer(item.id) {
                $0.state = .failed(message)
                $0.detail = item.kind == .install ? "Install failed" : "Transfer failed"
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

    func pasteClipboard(into session: ScrcpySession) {
        guard let string = NSPasteboard.general.string(forType: .string), !string.isEmpty else {
            showToast(icon: "doc.on.clipboard", title: "Clipboard is empty", detail: nil, isError: false)
            return
        }
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

