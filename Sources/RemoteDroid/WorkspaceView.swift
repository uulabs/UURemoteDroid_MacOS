import SwiftUI
import AppKit
import RemoteDroidCore

struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var keyboardActive = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader()
            Rectangle()
                .fill(Theme.stroke)
                .frame(height: 1)
            content
            if !model.transfers.isEmpty {
                TransferStrip()
                    .padding(.horizontal, 18)
                    .padding(.top, 7)
                    .padding(.bottom, 2)
            }
            ControlDock(keyboardActive: keyboardActive)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 14)
        }
        .background(Theme.background)
        .onChange(of: model.selectedSerial) { _, _ in
            keyboardActive = false
        }
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            Theme.backgroundLift
            DottedBackdrop(spacing: 25, dotColor: Color.white.opacity(0.045))
            stageGlow
            Group {
                if let device = model.selectedDevice {
                    if !device.isReady {
                        AuthorizationView(device: device)
                    } else if model.layoutMode == .grid {
                        DeviceWallView()
                    } else {
                        SingleDeviceStage(
                            device: device,
                            session: model.session(for: device.serial),
                            keyboardActive: $keyboardActive,
                            dropTargeted: $dropTargeted
                        )
                    }
                } else {
                    WelcomeView()
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty, model.selectedDevice?.isReady == true else { return false }
                model.sendFiles(urls)
                return true
            } isTargeted: { targeted in
                withAnimation(.easeOut(duration: 0.15)) { dropTargeted = targeted }
            }
            if dropTargeted {
                dropOverlay
            }
        }
        .clipped()
    }

    private var stageGlow: some View {
        GeometryReader { proxy in
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.055))
                    .frame(width: proxy.size.height * 0.82)
                    .blur(radius: 95)
                    .offset(x: proxy.size.width * 0.04, y: proxy.size.height * 0.24)
                Circle()
                    .fill(Theme.indigo.opacity(0.06))
                    .frame(width: proxy.size.height * 0.56)
                    .blur(radius: 85)
                    .offset(x: -proxy.size.width * 0.27, y: -proxy.size.height * 0.34)
            }
        }
        .allowsHitTesting(false)
    }

    private var dropOverlay: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.48))
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Theme.accent.opacity(0.065))
                )
                .padding(24)
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text("Drop to send")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text(dropHint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private var dropHint: String {
        guard let device = model.selectedDevice else { return "Choose a device first" }
        return "APKs install automatically · other files go to Download on \(device.displayName)"
    }
}

// MARK: - Header

private struct WorkspaceHeader: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            titleBlock
            Spacer(minLength: 18)
            actions
        }
        .padding(.horizontal, 22)
        .padding(.top, 26)
        .padding(.bottom, 15)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Text(title)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if model.layoutMode == .grid {
                    Pill(
                        icon: "rectangle.grid.2x2",
                        text: "\(model.wallDevices.count) OF \(model.readyDevices.count) DEVICES",
                        color: Theme.indigo,
                        background: Theme.indigo.opacity(0.08)
                    )
                } else if let session = model.activeSession {
                    HeaderSessionStatus(session: session)
                }
            }
            Text(subtitle)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
        }
    }

    private var title: String {
        if model.layoutMode == .grid {
            return "Device Wall"
        }
        if let device = model.selectedDevice {
            return device.displayName
        }
        return "RemoteDroid"
    }

    private var subtitle: String {
        if model.layoutMode == .grid {
            return "\(model.wallDevices.count) of \(model.readyDevices.count) selected · click a tile to control it"
        }
        guard let device = model.selectedDevice else {
            return "Choose a connected Android device to start"
        }
        var pieces: [String] = [device.connection.label]
        if let details = device.details {
            pieces.append(details.androidDescription)
            pieces.append(details.screenDescription)
        }
        if device.state == .unauthorized {
            pieces.append("Waiting for USB debugging authorization")
        } else {
            pieces.append(device.serial)
        }
        return pieces.joined(separator: "  ·  ")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            ModeSwitcher(mode: Binding(
                get: { model.layoutMode },
                set: { model.setLayout($0) }
            ))

            if model.layoutMode == .grid {
                LabelButton(symbol: "checklist", label: "Choose", prominent: false) {
                    model.showWallPicker.toggle()
                }
                .popover(isPresented: $model.showWallPicker, arrowEdge: .bottom) {
                    WallDevicePicker()
                        .environmentObject(model)
                }
            }

            LabelButton(
                symbol: "paperplane.fill",
                label: "Send",
                prominent: false
            ) {
                model.chooseFiles(installOnly: false)
            }
            .disabled(model.selectedDevice?.isReady != true)

            if model.layoutMode == .single {
                IconButton(symbol: "sidebar.right", help: "Toggle inspector", active: model.showInspector) {
                    model.showInspector.toggle()
                }
            }

            IconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Toggle full screen") {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }

            Menu {
                Button("Install APK…") {
                    model.chooseFiles(installOnly: true)
                }
                Button("Take screenshot") {
                    model.captureScreenshot()
                }
                Divider()
                Button("Restart stream") {
                    if let serial = model.selectedSerial {
                        model.retrySession(for: serial)
                    }
                }
                Button("Disconnect this device") {
                    if let serial = model.selectedSerial {
                        model.closeSession(for: serial)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.045))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30, height: 30)
            .help("More actions")
        }
    }
}

private struct HeaderSessionStatus: View {
    @ObservedObject var session: ScrcpySession

    var body: some View {
        switch session.phase {
        case .live:
            HStack(spacing: 5) {
                StatusDot(color: Theme.success, pulsing: true)
                Text("LIVE")
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.success)
                Text("\(Int(session.videoSize.width)) × \(Int(session.videoSize.height))")
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.textMuted)
                if session.fps >= 0.5 {
                    Text("\(Int(session.fps.rounded())) fps")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.textFaint)
                } else {
                    Text("static")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.textFaint)
                }
            }
        case .connecting:
            HStack(spacing: 5) {
                Spinner(color: Theme.warning)
                Text("CONNECTING")
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(Theme.warning)
            }
        case .failed:
            Pill(icon: "exclamationmark.triangle.fill", text: "STREAM ERROR", color: Theme.danger, background: Theme.danger.opacity(0.08))
        case .idle:
            Pill(text: "READY", color: Theme.textMuted, background: Color.white.opacity(0.04))
        }
    }
}

// MARK: - Welcome / authorization

private struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.07))
                    .frame(width: 128, height: 128)
                    .blur(radius: 12)
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Theme.panel)
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Theme.strokeStrong, lineWidth: 1)
                        )
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Theme.accentGradient)
                }
                .frame(width: 90, height: 90)
            }

            VStack(spacing: 7) {
                Text(model.adbProblem == nil ? "Bring a device to the screen" : "ADB needs a hand")
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text(
                    model.adbProblem == nil
                        ? "Phones and emulators appear here the moment ADB can see them. Select one and it opens instantly."
                        : (model.adbProblem ?? "Locate the adb executable to begin.")
                )
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 410)
            }

            HStack(spacing: 9) {
                LabelButton(symbol: "arrow.clockwise", label: "Refresh", prominent: true) {
                    model.refreshNow()
                }
                LabelButton(symbol: "folder", label: "Locate ADB") {
                    model.locateADB()
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                instruction("1", "Enable Developer options and USB debugging on the phone.")
                instruction("2", "Approve the “Allow USB debugging” prompt on the device.")
                instruction("3", "For an emulator, start it from Android Studio or your AVD manager.")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.025))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
            )

            HStack(spacing: 6) {
                Text("$")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.accent)
                Text("adb devices -l")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textMuted)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.black.opacity(0.28)).overlay(Capsule().stroke(Theme.stroke, lineWidth: 1)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private func instruction(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(Theme.mono(9, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.accent.opacity(0.10)))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AuthorizationView: View {
    @EnvironmentObject private var model: AppModel
    let device: AndroidDevice

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.warning)
                .frame(width: 78, height: 78)
                .background(Circle().fill(Theme.warning.opacity(0.07)))

            VStack(spacing: 7) {
                Text(device.state == .offline ? "Device is offline" : "Authorize USB debugging")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text(device.state == .offline
                     ? "ADB can see this device but cannot talk to it. Reconnect the cable or restart ADB, then try again."
                     : "Unlock \(device.displayName), then tap Allow on the USB debugging prompt. Tick “Always allow” if you want this Mac remembered.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 440)
            }

            Pill(icon: "cable.connector", text: device.serial, color: Theme.textMuted, background: Color.white.opacity(0.04), monospaced: true)

            HStack(spacing: 9) {
                LabelButton(symbol: "arrow.clockwise", label: "Check again", prominent: true) {
                    model.refreshNow()
                }
                LabelButton(symbol: "terminal", label: "Copy adb command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("adb devices -l", forType: .string)
                    model.showToast(icon: "terminal.fill", title: "Command copied", detail: "adb devices -l", isError: false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}


// MARK: - Wall device picker

struct WallDevicePicker: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Device Wall")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.text)
                    Text("Choose the devices shown side by side")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textFaint)
                }
                Spacer()
                Pill(
                    text: "\(model.wallDevices.count)/\(model.readyDevices.count)",
                    color: Theme.accent,
                    background: Theme.accent.opacity(0.08),
                    monospaced: true
                )
            }

            HStack(spacing: 7) {
                Button("Select all") { model.selectAllWallDevices() }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.08)))
                Button("Clear") { model.clearWallDevices() }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.035)))
                Spacer()
                Text("Up to six at a glance")
                    .font(.system(size: 8.5))
                    .foregroundStyle(Theme.textFaint)
            }

            Rectangle().fill(Theme.stroke).frame(height: 1)

            if model.readyDevices.isEmpty {
                Text("No connected devices")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(model.readyDevices) { device in
                            deviceRow(device)
                        }
                    }
                }
                .frame(maxHeight: 310)
            }

            Text("Selected devices keep a live mirror. Unselected devices stay connected but stop decoding until you add them.")
                .font(.system(size: 8.5))
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .padding(14)
        .frame(width: 322)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }

    private func deviceRow(_ device: AndroidDevice) -> some View {
        let selected = model.wallSerials.contains(device.serial)
        return Button {
            model.toggleWallDevice(device.serial)
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? Theme.accent : Color.white.opacity(0.035))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(selected ? Theme.accent : Theme.strokeStrong, lineWidth: 1)
                        )
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(hex: 0x06100E))
                    }
                }
                .frame(width: 18, height: 18)

                Image(systemName: device.connection == .emulator ? "display" : "iphone.gen3")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : Theme.textFaint)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(selected ? Theme.text : Theme.textMuted)
                        .lineLimit(1)
                    Text("\(device.connection.label) · \(device.serial)")
                        .font(Theme.mono(8))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if model.isSessionLive(device.serial) {
                    StatusDot(color: Theme.success, pulsing: true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.075) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? Theme.accent.opacity(0.15) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
