import SwiftUI
import AppKit
import RemoteDroidCore

struct InspectorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Theme.stroke)
                .frame(height: 1)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    if let device = model.selectedDevice, device.isReady {
                        streamCard(device: device)
                        deviceCard(device: device)
                        if !model.transfers.isEmpty {
                            transferCard
                        }
                        shortcutCard
                    } else {
                        placeholder
                    }
                }
                .padding(12)
            }
            footer
        }
        .frame(width: 270)
        .background(
            ZStack {
                Theme.sidebar
                LinearGradient(
                    colors: [Color.white.opacity(0.015), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        )
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.stroke).frame(width: 1)
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 7) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                Text("Inspector")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            Spacer()
            IconButton(symbol: "xmark", help: "Hide inspector", size: 24) {
                model.showInspector = false
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 28)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func streamCard(device: AndroidDevice) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                SectionLabel(text: "Stream")
                Spacer()
                if let session = model.session(for: device.serial) {
                    InspectorStreamBadge(session: session)
                }
            }

            if let session = model.session(for: device.serial) {
                InspectorStreamStats(session: session)
            } else {
                Text("No active stream")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textFaint)
            }

            Rectangle().fill(Theme.stroke).frame(height: 1)

            HStack(spacing: 4) {
                preset("Saver", config: .efficient)
                preset("Balanced", config: .balanced)
                preset("Native", config: .native)
            }

            Button {
                model.showSettings = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text("Custom stream settings")
                        .font(.system(size: 9.5, weight: .medium))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.03))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .inspectorCard()
    }

    private func preset(_ title: String, config: StreamConfiguration) -> some View {
        let selected = model.configuration == config
        return Button {
            guard model.configuration != config else { return }
            model.setConfiguration(config)
        } label: {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(selected ? Theme.accent : Theme.textMuted)
                .frame(maxWidth: .infinity)
                .frame(height: 27)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Theme.accent.opacity(0.09) : Color.white.opacity(0.025))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(selected ? Theme.accent.opacity(0.26) : Theme.stroke, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .help(config.summary)
    }

    private func deviceCard(device: AndroidDevice) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(text: "Device")
            infoRow("Android", value: device.details?.androidDescription ?? "—", icon: "cpu")
            infoRow("Display", value: device.details?.screenDescription ?? "—", icon: "rectangle.portrait")
            infoRow("Battery", value: batteryText(device), icon: "battery.75")
            infoRow("Storage free", value: device.details?.storageDescription ?? "—", icon: "internaldrive")
            infoRow("Transport", value: device.connection.label, icon: device.connection.symbol)
            Rectangle().fill(Theme.stroke).frame(height: 1)
            HStack(spacing: 5) {
                Image(systemName: "number")
                    .font(.system(size: 8.5))
                    .foregroundStyle(Theme.textFaint)
                Text(device.serial)
                    .font(Theme.mono(8.5))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(device.serial, forType: .string)
                    model.showToast(icon: "number", title: "Serial copied", detail: device.serial, isError: false)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 8.5))
                        .foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
                .help("Copy serial")
            }
        }
        .padding(12)
        .inspectorCard()
    }

    private var transferCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(text: "Transfers")
            ForEach(model.transfers.suffix(3)) { item in
                HStack(spacing: 7) {
                    transferIcon(item)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.fileName)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        if item.state == .running, item.kind == .push {
                            ProgressBar(value: item.progress, tint: Theme.accent)
                        } else {
                            Text(item.detail)
                                .font(.system(size: 8))
                                .foregroundStyle(item.state.isFailed ? Theme.danger : Theme.textFaint)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 2)
                    Button {
                        model.dismissTransfer(item.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(Theme.textFaint)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
            }
            Button {
                model.chooseFiles(installOnly: false)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Send another file")
                        .font(.system(size: 9.5, weight: .medium))
                }
                .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)
        }
        .padding(12)
        .inspectorCard()
    }

    @ViewBuilder
    private func transferIcon(_ item: AppModel.TransferItem) -> some View {
        switch item.state {
        case .queued:
            Image(systemName: "clock").font(.system(size: 8.5)).foregroundStyle(Theme.textFaint)
        case .running:
            Spinner(color: item.kind == .install ? Theme.violet : Theme.accent)
                .frame(width: 10, height: 10)
        case .completed:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 9)).foregroundStyle(Theme.success)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 9)).foregroundStyle(Theme.danger)
        }
    }

    private var shortcutCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Shortcuts")
            shortcutRow("Paste from Mac", keys: "⌘V")
            shortcutRow("Send files", keys: "⌘O")
            shortcutRow("Install APK", keys: "⌘⇧O")
            shortcutRow("Screenshot", keys: "⌘⇧S")
            shortcutRow("Single / Wall", keys: "⌘1 / ⌘2")
        }
        .padding(12)
        .inspectorCard()
    }

    private var placeholder: some View {
        VStack(spacing: 9) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.textFaint)
            Text("Select a device")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.textMuted)
            Text("Stream details, device information and transfer progress appear here.")
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.textFaint)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private var footer: some View {
        VStack(spacing: 7) {
            Rectangle().fill(Theme.stroke).frame(height: 1)
            HStack(spacing: 6) {
                LabelButton(symbol: "arrow.clockwise", label: "Restart") {
                    if let serial = model.selectedSerial {
                        model.retrySession(for: serial)
                    }
                }
                .disabled(model.selectedDevice?.isReady != true)
                LabelButton(symbol: "stop", label: "Stop") {
                    if let serial = model.selectedSerial {
                        model.closeSession(for: serial)
                    }
                }
                .disabled(model.session(for: model.selectedSerial ?? "") == nil)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
    }

    private func infoRow(_ label: String, value: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.textFaint)
                .frame(width: 12)
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.textMuted)
            Spacer()
            Text(value)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
        }
    }

    private func shortcutRow(_ label: String, keys: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.textMuted)
            Spacer()
            Text(keys)
                .font(Theme.mono(8.5, weight: .medium))
                .foregroundStyle(Theme.textFaint)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.035)))
        }
    }

    private func batteryText(_ device: AndroidDevice) -> String {
        guard let details = device.details, details.batteryLevel >= 0 else { return "—" }
        return "\(details.batteryLevel)%\(details.isCharging ? " ⚡" : "")"
    }
}

private struct InspectorStreamBadge: View {
    @ObservedObject var session: ScrcpySession
    var body: some View {
        switch session.phase {
        case .live:
            Pill(icon: "waveform", text: "H.264", color: Theme.accent, background: Theme.accent.opacity(0.07))
        case .connecting:
            HStack(spacing: 5) {
                Spinner(color: Theme.warning)
                Text("LINKING")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(Theme.warning)
            }
        case .failed:
            Pill(text: "ERROR", color: Theme.danger, background: Theme.danger.opacity(0.07))
        case .idle:
            Pill(text: "IDLE", color: Theme.textFaint, background: Color.white.opacity(0.03))
        }
    }
}

private struct InspectorStreamStats: View {
    @ObservedObject var session: ScrcpySession

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Resolution")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                Text(session.videoSize.width > 0 ? "\(Int(session.videoSize.width)) × \(Int(session.videoSize.height))" : "—")
                    .font(Theme.mono(9, weight: .medium))
                    .foregroundStyle(Theme.text)
            }
            HStack {
                Text("Framerate")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                Text(session.fps >= 0.5 ? "\(Int(session.fps.rounded())) fps" : "0 fps · static")
                    .font(Theme.mono(9, weight: .medium))
                    .foregroundStyle(Theme.text)
            }
            HStack {
                Text("Bitrate")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                Text(String(format: "%.1f Mbps", session.bitrateMbps))
                    .font(Theme.mono(9, weight: .medium))
                    .foregroundStyle(Theme.text)
            }
            HStack {
                Text("Decoder")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                Text("VideoToolbox")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.accent.opacity(0.85))
            }
        }
    }
}

private extension View {
    func inspectorCard() -> some View {
        self.background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.panel.opacity(0.72))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
        )
    }
}
