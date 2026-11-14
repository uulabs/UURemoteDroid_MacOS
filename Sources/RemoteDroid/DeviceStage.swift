import SwiftUI
import AppKit
import RemoteDroidCore

// MARK: - Single-device stage

struct SingleDeviceStage: View {
    @EnvironmentObject private var model: AppModel
    let device: AndroidDevice
    let session: ScrcpySession?
    @Binding var keyboardActive: Bool
    @Binding var dropTargeted: Bool

    var body: some View {
        Group {
            if let session {
                ConnectedStage(
                    device: device,
                    session: session,
                    keyboardActive: $keyboardActive
                )
            } else {
                UnconnectedStage(device: device)
            }
        }
    }
}

private struct ConnectedStage: View {
    @EnvironmentObject private var model: AppModel
    let device: AndroidDevice
    @ObservedObject var session: ScrcpySession
    @Binding var keyboardActive: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = phoneSize(in: proxy.size)
            VStack(spacing: 12) {
                Spacer(minLength: 0)
                PhoneBezel(
                    cornerRadius: max(28, size.width * 0.115),
                    bezel: max(5, min(9, size.width * 0.026))
                ) {
                    surface
                }
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .trailing) { sideButtons(height: size.height) }
                .shadow(color: Color.black.opacity(0.62), radius: 32, y: 20)
                .overlay {
                    RoundedRectangle(cornerRadius: max(28, size.width * 0.115), style: .continuous)
                        .stroke(
                            keyboardActive ? Theme.accent.opacity(0.55) : Color.clear,
                            lineWidth: 1.5
                        )
                        .shadow(color: Theme.accent.opacity(keyboardActive ? 0.22 : 0), radius: 12)
                }

                stageCaption
                    .frame(width: size.width)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 18)
    }

    @ViewBuilder
    private var surface: some View {
        ZStack {
            Color.black
            switch session.phase {
            case .live:
                if session.videoSize.width > 0 {
                    RemoteScreenView(
                        session: session,
                        onKeyboardFocusChange: { focused in
                            keyboardActive = focused
                        }
                    )
                    .overlay { ScreenOffOverlay(session: session) }
                } else {
                    ConnectingSurface(device: device, message: "Starting the video stream")
                }
            case .connecting:
                ConnectingSurface(device: device, message: "Starting a low-latency session")
            case .failed(let message):
                StreamErrorSurface(
                    message: message,
                    retry: { model.retrySession(for: device.serial) }
                )
            case .idle:
                ConnectSurface(device: device) {
                    model.ensureSession(for: device)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.phase)
    }

    private var stageCaption: some View {
        HStack(spacing: 7) {
            switch session.phase {
            case .live:
                StatusDot(color: Theme.success, pulsing: true)
                Text("LIVE")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.success)
                if session.fps >= 0.5 {
                    Text("\(Int(session.fps.rounded())) fps")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.textFaint)
                    Text("·")
                        .foregroundStyle(Theme.textFaint.opacity(0.5))
                    Text(String(format: "%.1f Mbps", session.bitrateMbps))
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.textFaint)
                } else {
                    Text("static frame")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.textFaint)
                }
            case .connecting:
                Spinner(color: Theme.warning)
                Text("CONNECTING")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.warning)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8.5))
                    .foregroundStyle(Theme.danger)
                Text("STREAM STOPPED")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.danger)
            case .idle:
                Circle().fill(Theme.textFaint).frame(width: 5, height: 5)
                Text("NOT CONNECTED")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.textFaint)
            }
            Spacer(minLength: 4)
            if keyboardActive {
                Image(systemName: "keyboard.fill")
                    .font(.system(size: 8.5))
                    .foregroundStyle(Theme.accent)
                Text("Keyboard active")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.accent)
            } else {
                Text("Click screen · right-click = Back")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .lineLimit(1)
    }

    private func sideButtons(height: CGFloat) -> some View {
        VStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(hex: 0x2B3745))
                .frame(width: 2.5, height: min(38, height * 0.1))
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(hex: 0x222C38))
                .frame(width: 2.5, height: min(26, height * 0.07))
            Spacer().frame(height: min(64, height * 0.12))
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(hex: 0x2B3745))
                .frame(width: 2.5, height: min(46, height * 0.11))
        }
        .offset(x: 2.5)
    }

    private func phoneSize(in available: CGSize) -> CGSize {
        let ratio: CGFloat
        if session.videoSize.width > 0, session.videoSize.height > 0 {
            ratio = session.videoSize.width / session.videoSize.height
        } else if let details = device.details, details.screenHeight > 0 {
            ratio = CGFloat(details.screenWidth) / CGFloat(details.screenHeight)
        } else {
            ratio = 9.0 / 19.5
        }
        let maxWidth = max(200, available.width - 140)
        let maxHeight = max(280, available.height - 48)
        var width = maxHeight * ratio
        var height = maxHeight
        if width > maxWidth {
            width = maxWidth
            height = width / ratio
        }
        return CGSize(width: width, height: height)
    }
}

// MARK: - Placeholder states

private struct UnconnectedStage: View {
    @EnvironmentObject private var model: AppModel
    let device: AndroidDevice

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(Theme.stroke, lineWidth: 1)
                    .frame(width: 150, height: 150)
                Circle()
                    .stroke(Theme.stroke.opacity(0.6), lineWidth: 1)
                    .frame(width: 190, height: 190)
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Theme.panel)
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Theme.strokeStrong, lineWidth: 1))
                    .frame(width: 88, height: 154)
                Image(systemName: device.connection == .emulator ? "display" : "iphone.gen3")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.accentGradient)
                Spinner(color: Theme.accent)
                    .offset(y: 46)
            }
            VStack(spacing: 6) {
                Text("Open \(device.displayName)")
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text("The device is connected over \(device.connection.label.lowercased()). Start a hardware-decoded mirror with full mouse and keyboard control.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 400)
            }
            LabelButton(symbol: "play.fill", label: "Start mirroring", prominent: true) {
                model.ensureSession(for: device)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

private struct ConnectSurface: View {
    let device: AndroidDevice
    let connect: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.circle")
                .font(.system(size: 32, weight: .thin))
                .foregroundStyle(Theme.accent)
            Text("Session stopped")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
            LabelButton(symbol: "play.fill", label: "Connect", prominent: true, action: connect)
        }
        .padding(22)
    }
}

private struct ConnectingSurface: View {
    let device: AndroidDevice
    let message: String
    @State private var animate = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x0B1219), Color(hex: 0x071016)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(Theme.accent.opacity(0.12), lineWidth: 1)
                        .frame(width: 92, height: 92)
                    Circle()
                        .trim(from: 0.1, to: 0.55)
                        .stroke(Theme.accentGradient, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 64, height: 64)
                        .rotationEffect(.degrees(animate ? 360 : 0))
                        .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: animate)
                    Image(systemName: device.connection == .emulator ? "display" : "iphone.gen3")
                        .font(.system(size: 23, weight: .light))
                        .foregroundStyle(Theme.textMuted)
                }
                VStack(spacing: 5) {
                    Text("Connecting")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(message)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textFaint)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(20)
        }
        .onAppear { animate = true }
    }
}

private struct StreamErrorSurface: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.danger)
            Text("Stream stopped")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
            ScrollView {
                Text(message)
                    .font(Theme.mono(8.5))
                    .foregroundStyle(Theme.textMuted)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(8)
            }
            .frame(maxHeight: 130)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
            )
            HStack(spacing: 7) {
                LabelButton(symbol: "arrow.clockwise", label: "Retry", prominent: true, action: retry)
                IconButton(symbol: "doc.on.doc", help: "Copy error") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                }
            }
        }
        .padding(18)
    }
}

// MARK: - Device wall

struct DeviceWallView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tileFrames: [String: CGRect] = [:]
    @State private var dragSerial: String?
    @State private var dragOffset: CGSize = .zero
    @State private var dropTarget: String?

    var body: some View {
        GeometryReader { proxy in
            let devices = model.wallDevices
            if devices.isEmpty {
                VStack(spacing: 13) {
                    Image(systemName: model.readyDevices.isEmpty ? "rectangle.grid.2x2" : "checklist")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(Theme.textFaint)
                    Text(model.readyDevices.isEmpty ? "No devices connected" : "Choose devices for the wall")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.text)
                    Text(model.readyDevices.isEmpty
                         ? "Connect a phone or start an emulator to begin."
                         : "Select any of your \(model.readyDevices.count) connected devices. You can change this at any time.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .frame(maxWidth: 360)
                    HStack(spacing: 8) {
                        if !model.readyDevices.isEmpty {
                            LabelButton(symbol: "checklist", label: "Choose devices", prominent: true) {
                                model.showWallPicker = true
                            }
                        }
                        LabelButton(symbol: "arrow.clockwise", label: "Refresh") { model.refreshNow() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if devices.count <= 4 {
                HStack(spacing: 12) {
                    ForEach(devices) { device in
                        tile(for: device)
                    }
                }
                .padding(16)
            } else if devices.count <= 6 {
                let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
                let tileHeight = max(190, (proxy.size.height - 32 - 12) / 2)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(devices) { device in
                        tile(for: device)
                            .frame(height: tileHeight)
                    }
                }
                .padding(16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(devices) { device in
                            tile(for: device)
                                .frame(width: 260)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .onPreferenceChange(WallTileFrameKey.self) { frames in
            tileFrames = frames
        }
    }

    private func tile(for device: AndroidDevice) -> some View {
        let serial = device.serial
        let isDragged = dragSerial == serial
        return WallTile(
            device: device,
            session: model.session(for: serial),
            isActive: model.selectedSerial == serial,
            isDragged: isDragged,
            isDropTarget: dropTarget == serial,
            onDragChanged: { translation, location in
                dragChanged(serial: serial, translation: translation, location: location)
            },
            onDragEnded: { dragEnded(serial: serial) }
        )
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: WallTileFrameKey.self,
                    value: [serial: geometry.frame(in: .global)]
                )
            }
        )
        .scaleEffect(isDragged ? 1.025 : 1)
        .opacity(isDragged ? 0.92 : 1)
        .offset(isDragged ? dragOffset : .zero)
        .zIndex(isDragged ? 10 : 0)
    }

    private func dragChanged(serial: String, translation: CGSize, location: CGPoint) {
        if dragSerial != serial {
            dragSerial = serial
            model.selectDevice(serial)
        }
        dragOffset = translation
        let target = tileFrames.first { key, frame in
            key != serial && frame.contains(location)
        }?.key
        if target != dropTarget {
            withAnimation(.easeOut(duration: 0.12)) { dropTarget = target }
        }
    }

    private func dragEnded(serial: String) {
        let target = dropTarget
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            if let target {
                model.moveWallDevice(serial, toSlotOf: target)
            }
            dragOffset = .zero
            dragSerial = nil
            dropTarget = nil
        }
    }
}

private struct WallTileFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct WallTile: View {
    @EnvironmentObject private var model: AppModel
    let device: AndroidDevice
    let session: ScrcpySession?
    let isActive: Bool
    var isDragged = false
    var isDropTarget = false
    var onDragChanged: (CGSize, CGPoint) -> Void = { _, _ in }
    var onDragEnded: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.panel.opacity(0.76))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(isActive ? Theme.accent.opacity(0.38) : Theme.stroke, lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(isDragged ? 0.45 : 0.18), radius: isDragged ? 22 : 12, y: isDragged ? 14 : 8)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isDropTarget ? Theme.accent : Color.clear, lineWidth: 2)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectDevice(device.serial)
        }
        .contextMenu {
            Button("Focus this device") {
                model.selectDevice(device.serial)
                model.setLayout(.single)
            }
            Button("Restart this stream") {
                model.retrySession(for: device.serial)
            }
            if let session, session.phase.isLive {
                Divider()
                Button("Turn screen on") { session.setScreen(on: true) }
                Button("Turn screen off") { session.setScreen(on: false) }
                Divider()
                Button("Rotate") { session.rotate() }
                Button("Turn auto-rotate back on") { session.restoreAutoRotate() }
            }
            Divider()
            Button("Move left") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    model.moveWallDevice(device.serial, by: -1)
                }
            }
            .disabled(wallIndex <= 0)
            Button("Move right") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    model.moveWallDevice(device.serial, by: 1)
                }
            }
            .disabled(wallIndex >= model.wallDevices.count - 1)
            Divider()
            Button("Hide from Device Wall") {
                model.toggleWallDevice(device.serial)
            }
        }
    }

    private var wallIndex: Int {
        model.wallDevices.firstIndex(where: { $0.serial == device.serial }) ?? 0
    }

    private var header: some View {
        HStack(spacing: 7) {
            // The grip, name and status form the drag handle. It is an AppKit
            // view so the drag reorders tiles instead of moving the window
            // (the window is movable by its background).
            HStack(spacing: 7) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(isDragged ? Theme.accent : Theme.textFaint)
                if activeStatusVisible {
                    StatusDot(color: Theme.success, pulsing: true)
                }
                Text(device.wallLabel)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let session {
                    WallStatus(session: session)
                }
                Spacer(minLength: 0)
                if isActive {
                    Text("ACTIVE")
                        .font(.system(size: 7.5, weight: .bold))
                        .tracking(0.9)
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 21)
            .overlay(
                WallDragHandle(
                    onClick: { model.selectDevice(device.serial) },
                    onChanged: onDragChanged,
                    onEnded: onDragEnded
                )
                .help("Drag to reorder the wall")
            )
            if let session {
                ScreenPowerButton(session: session)
            }
            Button {
                model.selectDevice(device.serial)
                model.setLayout(.single)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 21, height: 21)
                    .background(RoundedRectangle(cornerRadius: 5.5).fill(Color.white.opacity(0.04)))
            }
            .buttonStyle(.plain)
            .help("Focus \(device.displayName)")
        }
    }

    private var activeStatusVisible: Bool {
        session?.phase.isLive == true
    }

    @ViewBuilder
    private var content: some View {
        if let session {
            WallSessionContent(device: device, session: session)
        } else {
            VStack(spacing: 10) {
                Image(systemName: device.connection == .emulator ? "display" : "iphone.gen3")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.textFaint)
                LabelButton(symbol: "play.fill", label: "Connect", prominent: true) {
                    model.ensureSession(for: device)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.18))
        }
    }
}

private struct CompactStreamErrorSurface: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.danger)
            Text("Stream stopped")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("The device connection ended.")
                .font(.system(size: 8.5))
                .foregroundStyle(Theme.textFaint)
                .multilineTextAlignment(.center)
            Button(action: retry) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 8, weight: .bold))
                    Text("Retry")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Color(hex: 0x06100E))
                .padding(.horizontal, 10)
                .frame(height: 25)
                .background(Capsule().fill(Theme.accent))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .help(message)
    }
}

private struct WallStatus: View {
    @ObservedObject var session: ScrcpySession
    var body: some View {
        switch session.phase {
        case .live:
            if session.fps >= 0.5 {
                Text("\(Int(session.fps.rounded()))fps")
                    .font(Theme.mono(8.5))
                    .foregroundStyle(Theme.textFaint)
            } else {
                Text("static")
                    .font(Theme.mono(8.5))
                    .foregroundStyle(Theme.textFaint)
            }
        case .connecting:
            Spinner(color: Theme.warning)
                .frame(width: 10, height: 10)
        case .failed:
            Text("ERR")
                .font(Theme.mono(8, weight: .semibold))
                .foregroundStyle(Theme.danger)
        case .idle:
            EmptyView()
        }
    }
}

private struct WallSessionContent: View {
    @EnvironmentObject private var model: AppModel
    let device: AndroidDevice
    @ObservedObject var session: ScrcpySession

    var body: some View {
        GeometryReader { proxy in
            let size = phoneSize(in: proxy.size)
            VStack(spacing: 0) {
                Spacer(minLength: 5)
                PhoneBezel(
                    cornerRadius: max(16, size.width * 0.10),
                    bezel: 4
                ) {
                    surface
                }
                .frame(width: size.width, height: size.height)
                .shadow(color: Color.black.opacity(0.55), radius: 18, y: 10)
                Spacer(minLength: 5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            ZStack {
                Color.black.opacity(0.16)
                DottedBackdrop(spacing: 21, dotColor: Color.white.opacity(0.035))
            }
        )
    }

    @ViewBuilder
    private var surface: some View {
        switch session.phase {
        case .live:
            if session.videoSize.width > 0 {
                RemoteScreenView(
                    session: session,
                    onActivate: { model.selectDevice(device.serial) }
                )
                .overlay { ScreenOffOverlay(session: session, compact: true) }
            } else {
                ConnectingSurface(device: device, message: "Starting video")
            }
        case .connecting:
            ConnectingSurface(device: device, message: "Starting session")
        case .failed(let message):
            CompactStreamErrorSurface(message: message) {
                model.retrySession(for: device.serial)
            }
        case .idle:
            ConnectSurface(device: device) {
                model.ensureSession(for: device)
            }
        }
    }

    private func phoneSize(in available: CGSize) -> CGSize {
        let ratio: CGFloat
        if session.videoSize.width > 0, session.videoSize.height > 0 {
            ratio = session.videoSize.width / session.videoSize.height
        } else if let details = device.details, details.screenHeight > 0 {
            ratio = CGFloat(details.screenWidth) / CGFloat(details.screenHeight)
        } else {
            ratio = 9.0 / 19.5
        }
        let maxWidth = max(120, available.width - 28)
        let maxHeight = max(190, available.height - 20)
        var width = maxHeight * ratio
        var height = maxHeight
        if width > maxWidth {
            width = maxWidth
            height = width / ratio
        }
        return CGSize(width: width, height: height)
    }
}

// MARK: - Bezel

struct PhoneBezel<Content: View>: View {
    var cornerRadius: CGFloat = 34
    var bezel: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x26313D), Color(hex: 0x080B0F)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.13), lineWidth: 1)
                )
            RoundedRectangle(cornerRadius: max(8, cornerRadius - bezel), style: .continuous)
                .fill(Color.black)
                .padding(bezel)
                .overlay(
                    RoundedRectangle(cornerRadius: max(8, cornerRadius - bezel), style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                        .padding(bezel)
                )
            content()
                .clipShape(RoundedRectangle(cornerRadius: max(8, cornerRadius - bezel), style: .continuous))
                .padding(bezel)
        }
    }
}


private extension AndroidDevice {
    var wallLabel: String {
        if connection == .emulator, let port = serial.split(separator: "-").last {
            return "\(displayName) \(port)"
        }
        return displayName
    }
}


// MARK: - Tile drag handle

/// An AppKit drag surface for a wall tile header. SwiftUI drag gestures in
/// this window lose the mouse to window dragging, so the handle tracks the
/// mouse itself and reports the translation and the pointer location in the
/// window's top-left (SwiftUI global) coordinate space.
private struct WallDragHandle: NSViewRepresentable {
    var onClick: () -> Void
    var onChanged: (CGSize, CGPoint) -> Void
    var onEnded: () -> Void

    func makeNSView(context: Context) -> WallDragHandleView {
        let view = WallDragHandleView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: WallDragHandleView, context: Context) {
        update(nsView)
    }

    private func update(_ view: WallDragHandleView) {
        view.onClick = onClick
        view.onChanged = onChanged
        view.onEnded = onEnded
    }
}

final class WallDragHandleView: NSView {
    var onClick: () -> Void = {}
    var onChanged: (CGSize, CGPoint) -> Void = { _, _ in }
    var onEnded: () -> Void = {}

    private var startPoint: CGPoint?
    private var dragging = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: dragging ? .closedHand : .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = topLeftPoint(for: event)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint, let point = topLeftPoint(for: event) else { return }
        let translation = CGSize(width: point.x - start.x, height: point.y - start.y)
        if !dragging {
            guard hypot(translation.width, translation.height) >= 4 else { return }
            dragging = true
            NSCursor.closedHand.set()
        }
        onChanged(translation, point)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            startPoint = nil
            dragging = false
            window?.invalidateCursorRects(for: self)
        }
        if dragging {
            onEnded()
        } else {
            onClick()
        }
    }

    private func topLeftPoint(for event: NSEvent) -> CGPoint? {
        guard let content = window?.contentView else { return nil }
        let point = content.convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: content.isFlipped ? point.y : content.bounds.height - point.y)
    }
}

// MARK: - Screen power

/// Dims a mirror whose phone screen is off. Some phones keep sending their
/// lock screen after the panel turns off, so the mirror alone can look on.
/// The dimming lets clicks through to the mirror; the Wake button wakes it.
struct ScreenOffOverlay: View {
    @ObservedObject var session: ScrcpySession
    var compact = false

    var body: some View {
        if session.screenOn == false {
            ZStack {
                Color.black.opacity(0.62)
                    .allowsHitTesting(false)
                VStack(spacing: compact ? 8 : 12) {
                    Image(systemName: "moon.fill")
                        .font(.system(size: compact ? 20 : 28, weight: .light))
                        .foregroundStyle(Theme.textMuted)
                        .allowsHitTesting(false)
                    Text("Screen off")
                        .font(.system(size: compact ? 12 : 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .allowsHitTesting(false)
                    Button {
                        session.setScreen(on: true)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "power")
                                .font(.system(size: compact ? 9 : 10.5, weight: .bold))
                            Text("Wake")
                                .font(.system(size: compact ? 10 : 11.5, weight: .semibold))
                        }
                        .foregroundStyle(Color(hex: 0x06100E))
                        .padding(.horizontal, compact ? 11 : 14)
                        .frame(height: compact ? 25 : 30)
                        .background(Capsule().fill(Theme.accent))
                    }
                    .buttonStyle(.plain)
                    .help("Turn the phone screen on")
                }
            }
            .transition(.opacity)
        }
    }
}

/// Turns the phone's own screen on or off. Green when the screen is on.
struct ScreenPowerButton: View {
    @ObservedObject var session: ScrcpySession
    var size: CGFloat = 21

    var body: some View {
        let isOn = session.screenOn != false
        Button {
            session.toggleScreen()
        } label: {
            Image(systemName: "power")
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(isOn ? Theme.success : Theme.textFaint)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.26)
                        .fill(isOn ? Theme.success.opacity(0.12) : Color.white.opacity(0.04))
                )
        }
        .buttonStyle(.plain)
        .disabled(!session.phase.isLive)
        .opacity(session.phase.isLive ? 1 : 0.4)
        .help(isOn ? "Turn the phone screen off" : "Turn the phone screen on")
        .accessibilityLabel(isOn ? "Turn screen off" : "Turn screen on")
    }
}
