import SwiftUI
import RemoteDroidCore

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            brand
                .padding(.horizontal, 18)
                .padding(.top, 34)
                .padding(.bottom, 22)

            devicesHeader
                .padding(.horizontal, 16)
                .padding(.bottom, 9)

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 5) {
                    ForEach(model.devices) { device in
                        DeviceRow(
                            device: device,
                            isSelected: model.selectedSerial == device.serial,
                            session: model.session(for: device.serial)
                        ) {
                            model.selectDevice(device.serial)
                        }
                    }

                    if model.devices.isEmpty {
                        emptyDevices
                    }

                    if !model.readyDevices.isEmpty {
                        openAllButton
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }

            Spacer(minLength: 6)
            footer
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
        }
        .frame(width: 282)
        .background(
            ZStack {
                Theme.sidebar
                LinearGradient(
                    colors: [Color.white.opacity(0.018), Color.clear, Color.black.opacity(0.12)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        )
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.02), Color.white.opacity(0.09), Color.white.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 1)
        }
    }

    private var brand: some View {
        HStack(spacing: 11) {
            AppMark(size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("UU RemoteDroid")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text("ADB DEVICE CONSOLE")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(1.55)
                    .foregroundStyle(Theme.textFaint)
            }
            Spacer(minLength: 0)
        }
    }

    private var devicesHeader: some View {
        HStack(spacing: 6) {
            SectionLabel(text: "Devices")
            Text("\(model.devices.count)")
                .font(Theme.mono(9, weight: .medium))
                .foregroundStyle(Theme.textFaint)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.white.opacity(0.045)))
            Spacer()
            if model.isRefreshing {
                Spinner(color: Theme.textFaint)
                    .frame(width: 20, height: 20)
            } else {
                IconButton(symbol: "arrow.clockwise", help: "Refresh devices", size: 24) {
                    model.refreshNow()
                }
            }
            IconButton(symbol: "rectangle.grid.2x2", help: "Open all devices", active: model.layoutMode == .grid, size: 24) {
                model.setLayout(model.layoutMode == .grid ? .single : .grid)
            }
        }
    }

    private var openAllButton: some View {
        Button {
            model.setLayout(.grid)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.grid.2x2")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(wallButtonTitle)
                    .font(.system(size: 10.5, weight: .medium))
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Theme.textMuted)
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.025))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                            .foregroundStyle(Color.white.opacity(0.10))
                    )
            )
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .help("Open the device wall")
    }

    private var wallButtonTitle: String {
        let selected = model.wallDevices.count
        let ready = model.readyDevices.count
        if selected == 0 {
            return "Choose devices for the wall"
        }
        if selected == ready {
            return "Device wall · all \(ready)"
        }
        return "Device wall · \(selected) of \(ready)"
    }

    private var emptyDevices: some View {
        VStack(spacing: 10) {
            Image(systemName: model.adbProblem == nil ? "iphone.slash" : "exclamationmark.triangle")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(model.adbProblem == nil ? Theme.textFaint : Theme.warning)
            Text(model.adbProblem == nil ? "No devices detected" : "ADB not found")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.textMuted)
            Text(
                model.adbProblem == nil
                    ? "Connect a phone by USB, start an emulator, or enable wireless debugging."
                    : "Choose your Android platform-tools/adb executable."
            )
            .font(.system(size: 10))
            .foregroundStyle(Theme.textFaint)
            .multilineTextAlignment(.center)
            .lineSpacing(2)

            if model.adbProblem != nil {
                LabelButton(symbol: "folder", label: "Locate ADB", prominent: false) {
                    model.locateADB()
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 26)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.022))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.stroke, lineWidth: 1)
                )
        )
        .padding(.top, 6)
    }

    private var footer: some View {
        VStack(spacing: 9) {
            Rectangle()
                .fill(Theme.stroke)
                .frame(height: 1)
                .padding(.bottom, 1)

            HStack(spacing: 8) {
                StatusDot(color: model.adbProblem == nil ? Theme.success : Theme.warning, pulsing: false)
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(model.adbProblem == nil ? "ADB READY" : "ADB OFFLINE")
                        .font(.system(size: 8.5, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(model.adbProblem == nil ? Theme.success : Theme.warning)
                    Text(model.adbPathDisplay)
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                IconButton(symbol: "gearshape", help: "Settings", size: 26) {
                    model.showSettings = true
                }
            }

            HStack(spacing: 6) {
                LabelButton(symbol: "folder.badge.gearshape", label: "ADB", disabled: false) {
                    model.locateADB()
                }
                Spacer()
                if let version = model.adbDisplayVersion {
                    Text(version)
                        .font(Theme.mono(8.5))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct DeviceRow: View {
    let device: AndroidDevice
    let isSelected: Bool
    let session: ScrcpySession?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                deviceIcon
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(device.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Spacer(minLength: 3)
                        status
                    }
                    HStack(spacing: 5) {
                        Text(device.connection.label)
                            .font(.system(size: 8, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(device.connection == .emulator ? Theme.indigo : Theme.textMuted)
                        Text("·")
                            .foregroundStyle(Theme.textFaint)
                        Text(device.serial)
                            .font(Theme.mono(9))
                            .foregroundStyle(Theme.textFaint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isSelected
                            ? LinearGradient(
                                colors: [Theme.accent.opacity(0.105), Theme.blue.opacity(0.045)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            : LinearGradient(
                                colors: [hovering ? Color.white.opacity(0.045) : Color.clear, Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Theme.accent.opacity(0.24) : (hovering ? Theme.stroke : Color.clear), lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(Theme.accentGradient)
                        .frame(width: 2.5, height: 22)
                        .offset(x: 0.5)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(device.displayName), \(device.connection.label), \(device.state.rawValue)")
    }

    private var deviceIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                .fill(
                    isSelected
                        ? AnyShapeStyle(Theme.brandGradient)
                        : AnyShapeStyle(Color.white.opacity(0.045))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                        .stroke(isSelected ? Theme.accent.opacity(0.25) : Theme.stroke, lineWidth: 1)
                )
            Image(systemName: device.connection == .emulator ? "display" : "iphone.gen3")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(isSelected ? Theme.accent : Theme.textMuted)
        }
        .frame(width: 31, height: 31)
    }

    @ViewBuilder
    private var status: some View {
        if device.state == .unauthorized {
            Image(systemName: "lock.fill")
                .font(.system(size: 8))
                .foregroundStyle(Theme.warning)
                .help("Allow USB debugging on the device")
        } else if device.state == .offline {
            Pill(text: "OFFLINE", color: Theme.danger.opacity(0.9), background: Theme.danger.opacity(0.08))
        } else if let session {
            SessionStatusMini(session: session)
        } else if device.isReady {
            Circle()
                .fill(Theme.success.opacity(0.6))
                .frame(width: 5, height: 5)
        }
    }
}

private struct SessionStatusMini: View {
    @ObservedObject var session: ScrcpySession

    var body: some View {
        switch session.phase {
        case .live:
            Pill(text: "LIVE", color: Theme.success, background: Theme.success.opacity(0.075))
        case .connecting:
            HStack(spacing: 4) {
                Spinner(color: Theme.warning)
                    .frame(width: 9, height: 9)
            }
        case .failed:
            Pill(text: "RETRY", color: Theme.danger, background: Theme.danger.opacity(0.075))
        case .idle:
            Circle().fill(Theme.textFaint).frame(width: 5, height: 5)
        }
    }
}
