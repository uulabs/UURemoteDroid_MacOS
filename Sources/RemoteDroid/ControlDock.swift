import SwiftUI
import AppKit
import RemoteDroidCore

// MARK: - Bottom control dock

struct ControlDock: View {
    @EnvironmentObject private var model: AppModel
    var keyboardActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            deviceIdentity
                .frame(width: 185, alignment: .leading)

            Spacer(minLength: 8)

            if let session = model.activeSession {
                DockButtons(session: session, keyboardActive: keyboardActive)
            } else {
                DisabledDockButtons()
            }

            Spacer(minLength: 8)

            rightStatus
                .frame(width: 170, alignment: .trailing)
        }
        .padding(.horizontal, 13)
        .frame(height: 54)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(hex: 0x0C1219).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.09), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.30), radius: 16, y: 6)
        )
    }

    private var deviceIdentity: some View {
        HStack(spacing: 8) {
            if let device = model.selectedDevice {
                ZStack {
                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                        .fill(Color.white.opacity(0.045))
                        .overlay(RoundedRectangle(cornerRadius: 7.5, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
                    Image(systemName: device.connection == .emulator ? "display" : "iphone.gen3")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                }
                .frame(width: 27, height: 27)
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(device.displayName)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(device.connection.label)
                        .font(.system(size: 7.5, weight: .semibold))
                        .tracking(0.7)
                        .foregroundStyle(Theme.textFaint)
                }
            } else {
                Image(systemName: "iphone.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textFaint)
                Text("No device")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.textFaint)
            }
        }
    }

    private var rightStatus: some View {
        HStack(spacing: 7) {
            if let session = model.activeSession {
                Button {
                    model.captureScreenshot()
                } label: {
                    Image(systemName: "camera")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.03)))
                }
                .buttonStyle(.plain)
                .help("Save a screenshot")
                .accessibilityLabel("Save a screenshot")

                Button {
                    model.pasteClipboard(into: session)
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.03)))
                }
                .buttonStyle(.plain)
                .help("Paste Mac clipboard into the device (⌘V)")
                .accessibilityLabel("Paste clipboard")

                Rectangle()
                    .fill(Theme.stroke)
                    .frame(width: 1, height: 18)
                    .padding(.horizontal, 1)
            }

            HStack(spacing: 5) {
                Image(systemName: keyboardActive ? "keyboard.fill" : "cursorarrow.click")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(keyboardActive ? Theme.accent : Theme.textFaint)
                Text(keyboardActive ? "Keyboard active" : (model.layoutMode == .grid ? "Click a screen" : "Click screen to type"))
                    .font(.system(size: 9))
                    .foregroundStyle(keyboardActive ? Theme.accent : Theme.textFaint)
                    .lineLimit(1)
            }
        }
    }
}

private struct DockButtons: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: ScrcpySession
    var keyboardActive: Bool

    private var enabled: Bool { session.phase.isLive }

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) {
                DockButton(symbol: "chevron.backward", help: "Back", enabled: enabled) {
                    session.pressBack()
                }
                DockButton(symbol: "house", help: "Home", enabled: enabled) {
                    session.pressHome()
                }
                DockButton(symbol: "rectangle.on.rectangle", help: "Recent apps", enabled: enabled) {
                    session.pressAppSwitch()
                }
            }
            .dockGroup()

            HStack(spacing: 2) {
                DockButton(symbol: "speaker.minus", help: "Volume down", enabled: enabled) {
                    session.pressVolumeDown()
                }
                DockButton(symbol: "speaker.plus", help: "Volume up", enabled: enabled) {
                    session.pressVolumeUp()
                }
                DockButton(
                    symbol: "power",
                    help: session.screenOn == false ? "Turn the phone screen on" : "Turn the phone screen off",
                    enabled: enabled
                ) {
                    session.toggleScreen()
                }
                DockButton(symbol: "rotate.right", help: "Rotate device (right-click to turn auto-rotate back on)", enabled: enabled) {
                    session.rotate()
                }
                .contextMenu {
                    Button("Turn auto-rotate back on") { session.restoreAutoRotate() }
                }
                DockButton(symbol: "bell", help: "Open notifications", enabled: enabled) {
                    session.expandNotifications()
                }
            }
            .dockGroup()

            HStack(spacing: 2) {
                DockButton(symbol: "doc.on.clipboard", help: "Paste clipboard (⌘V)", enabled: enabled) {
                    model.pasteClipboard(into: session)
                }
                DockButton(symbol: "camera", help: "Screenshot", enabled: enabled) {
                    model.captureScreenshot()
                }
            }
            .dockGroup()
        }
    }
}

private struct DisabledDockButtons: View {
    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) {
                DockButton(symbol: "chevron.backward", help: "Back", enabled: false) {}
                DockButton(symbol: "house", help: "Home", enabled: false) {}
                DockButton(symbol: "rectangle.on.rectangle", help: "Recent apps", enabled: false) {}
            }
            .dockGroup()
            HStack(spacing: 2) {
                DockButton(symbol: "speaker.minus", help: "Volume down", enabled: false) {}
                DockButton(symbol: "speaker.plus", help: "Volume up", enabled: false) {}
                DockButton(symbol: "power", help: "Power / lock", enabled: false) {}
                DockButton(symbol: "rotate.right", help: "Rotate device", enabled: false) {}
            }
            .dockGroup()
        }
    }
}

private struct DockButton: View {
    var symbol: String
    var help: String
    var enabled: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(enabled ? (hovering ? Theme.text : Theme.textMuted) : Theme.textFaint.opacity(0.45))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering && enabled ? Color.white.opacity(0.065) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private extension View {
    func dockGroup() -> some View {
        self
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.black.opacity(0.16))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.stroke, lineWidth: 0.7))
            )
    }
}

// MARK: - Transfer strip

struct TransferStrip: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(model.transfers.suffix(4)) { item in
                    TransferChip(item: item) {
                        model.dismissTransfer(item.id)
                    }
                }
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 38)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.18), value: model.transfers)
    }
}

private struct TransferChip: View {
    let item: AppModel.TransferItem
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            stateIcon
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(item.fileName)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if item.kind == .install {
                        Text("APK")
                            .font(.system(size: 7, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(Theme.violet)
                    }
                    Text(stateText)
                        .font(Theme.mono(8))
                        .foregroundStyle(stateColor)
                }
                if item.state == .running, item.kind == .push {
                    ProgressBar(value: item.progress, tint: Theme.accent)
                        .frame(width: 155)
                } else if item.state.isFailed {
                    Text(item.detail)
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.danger.opacity(0.85))
                        .lineLimit(1)
                } else {
                    Text(item.detail)
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                }
            }
            .frame(width: 210, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 15, height: 15)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.panel.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(item.state.isFailed ? Theme.danger.opacity(0.20) : Theme.stroke, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch item.state {
        case .queued:
            Image(systemName: "clock")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.textFaint)
        case .running:
            Spinner(color: item.kind == .install ? Theme.violet : Theme.accent)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.success)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.danger)
        }
    }

    private var stateText: String {
        switch item.state {
        case .queued: return "QUEUED"
        case .running:
            if item.kind == .install { return "INSTALLING" }
            return "\(Int(item.progress * 100))%"
        case .completed: return item.kind == .install ? "INSTALLED" : "SENT"
        case .failed: return "FAILED"
        }
    }

    private var stateColor: Color {
        switch item.state {
        case .queued: return Theme.textFaint
        case .running: return item.kind == .install ? Theme.violet : Theme.accent
        case .completed: return Theme.success
        case .failed: return Theme.danger
        }
    }
}
