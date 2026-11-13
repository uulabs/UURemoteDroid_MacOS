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
                        WallTile(
                            device: device,
                            session: model.session(for: device.serial),
                            isActive: model.selectedSerial == device.serial
                        )
                    }
                }
                .padding(16)
            } else if devices.count <= 6 {
                let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
                let tileHeight = max(190, (proxy.size.height - 32 - 12) / 2)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(devices) { device in
                        WallTile(
                            device: device,
                            session: model.session(for: device.serial),
                            isActive: model.selectedSerial == device.serial
                        )
                        .frame(height: tileHeight)
                    }
                }
                .padding(16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(devices) { device in
                            WallTile(
                                device: device,
                                session: model.session(for: device.serial),
                                isActive: model.selectedSerial == device.serial
                            )
                            .frame(width: 260)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

private struct WallTile: View {
    @EnvironmentObject private var model: AppModel
    let device: AndroidDevice
    let session: ScrcpySession?
    let isActive: Bool

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
        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 8)
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
            Divider()
            Button("Hide from Device Wall") {
                model.toggleWallDevice(device.serial)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
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
