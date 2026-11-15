import SwiftUI
import AppKit
import RemoteDroidCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = StreamConfiguration.balanced
    @State private var didLoad = false
    @AppStorage(UpdateService.autoCheckDefaultsKey) private var autoUpdateChecks = true

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Rectangle().fill(Theme.stroke).frame(height: 1)
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        adbSection
                        streamSection
                        filesSection
                        clipboardSection
                        updatesSection
                        aboutSection
                    }
                    .padding(18)
                }
                footer
            }
        }
        .frame(width: 620, height: 690)
        .onAppear {
            guard !didLoad else { return }
            draft = model.configuration
            didLoad = true
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Settings")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text("Connection, stream and file handling")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
            IconButton(symbol: "xmark", help: "Close settings", size: 28) {
                dismiss()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private var adbSection: some View {
        settingsCard(title: "ADB", subtitle: "Platform tools used to discover and control devices") {
            VStack(spacing: 11) {
                HStack(spacing: 9) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.accent.opacity(0.08))
                        Image(systemName: "terminal")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.accent)
                    }
                    .frame(width: 31, height: 31)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.adbPathDisplay)
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(model.adbDisplayVersion.map { "adb \($0)" } ?? "Not available")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textFaint)
                    }
                    Spacer()
                    Pill(
                        text: model.adbProblem == nil ? "READY" : "MISSING",
                        color: model.adbProblem == nil ? Theme.success : Theme.warning,
                        background: (model.adbProblem == nil ? Theme.success : Theme.warning).opacity(0.075)
                    )
                }
                HStack(spacing: 7) {
                    LabelButton(symbol: "folder", label: "Locate adb…") {
                        model.locateADB()
                    }
                    LabelButton(symbol: "wand.and.stars", label: "Find automatically") {
                        model.useAutomaticADB()
                    }
                    Spacer()
                }
                Toggle(isOn: $model.autoConnectOnLaunch) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Connect to the first device on launch")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.text)
                        Text("You can still switch devices from the sidebar at any time.")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textFaint)
                    }
                }
                .toggleStyle(.switch)
                .tint(Theme.accent)
            }
        }
    }

    private var streamSection: some View {
        settingsCard(title: "Stream", subtitle: "Quality settings are applied to every active device") {
            VStack(spacing: 10) {
                settingRow(
                    title: "Resolution",
                    detail: "Longest edge of the mirrored video",
                    icon: "rectangle.portrait"
                ) {
                    Picker("", selection: $draft.maxSize) {
                        Text("Native").tag(0)
                        Text("2560 px").tag(2560)
                        Text("1920 px").tag(1920)
                        Text("1600 px").tag(1600)
                        Text("1280 px").tag(1280)
                        Text("1024 px").tag(1024)
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }

                settingRow(
                    title: "Frame rate",
                    detail: "Cap the stream to save bandwidth",
                    icon: "speedometer"
                ) {
                    Picker("", selection: $draft.maxFPS) {
                        Text("Display max").tag(0)
                        Text("120 fps").tag(120)
                        Text("90 fps").tag(90)
                        Text("60 fps").tag(60)
                        Text("30 fps").tag(30)
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }

                settingRow(
                    title: "Video bitrate",
                    detail: "Higher values preserve more detail in motion",
                    icon: "waveform.path.ecg"
                ) {
                    Picker("", selection: $draft.bitRate) {
                        Text("8 Mbps").tag(8_000_000)
                        Text("16 Mbps").tag(16_000_000)
                        Text("24 Mbps").tag(24_000_000)
                        Text("32 Mbps").tag(32_000_000)
                        Text("48 Mbps").tag(48_000_000)
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }

                HStack {
                    Toggle(isOn: $draft.keepAwake) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Keep the device awake while mirrored")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Theme.text)
                            Text("Restores the device setting when the stream closes.")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.textFaint)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(Theme.accent)
                    Spacer()
                }

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9))
                    Text("Scrcpy 5 · H.264 · VideoToolbox hardware decoding · audio disabled for minimal latency")
                        .font(.system(size: 9))
                }
                .foregroundStyle(Theme.textFaint)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var filesSection: some View {
        settingsCard(title: "Files", subtitle: "Drop files onto the mirror to send them instantly") {
            VStack(spacing: 9) {
                Toggle(isOn: $model.installAPKsOnDrop) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Install dropped APKs")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.text)
                        Text("Other files are copied to /sdcard/Download.")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textFaint)
                    }
                }
                .toggleStyle(.switch)
                .tint(Theme.accent)

                HStack {
                    Text("Device destination")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Text("/sdcard/Download")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.035)))
                }
            }
        }
    }

    private var clipboardSection: some View {
        settingsCard(title: "Clipboard", subtitle: "Share copied text between this Mac and your devices") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $model.clipboardSyncEnabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Sync clipboard across devices")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.text)
                        Text("Copy on one device and paste on another, or copy on the Mac and paste on a device.")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .tint(Theme.accent)

                Text("Text only. While enabled, text copied on this Mac is sent to every live device, and text copied on a device updates the Mac clipboard.")
                    .font(.system(size: 8.5))
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var aboutSection: some View {
        settingsCard(title: "About", subtitle: "UU Labs · UU RemoteDroid") {
            VStack(spacing: 8) {
                aboutRow("Version", value: appVersion)
                aboutRow("scrcpy server", value: "5.0.1")
                aboutRow("Decoder", value: "VideoToolbox")
                aboutRow("scrcpy licence", value: "Apache-2.0 · © Genymobile, Romain Vimont")
                HStack(spacing: 12) {
                    Link("scrcpy on GitHub", destination: URL(string: "https://github.com/Genymobile/scrcpy")!)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.accent)
                    if let license = Bundle.main.url(forResource: "SCRCPY-LICENSE", withExtension: "txt") {
                        Link("Licence text", destination: license)
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.accent)
                    }
                    if let notices = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") {
                        Link("Third-party notices", destination: notices)
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.accent)
                    }
                    Spacer()
                    Text("Built for macOS")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textFaint)
                }
            }
        }
    }

    private var updatesSection: some View {
        settingsCard(title: "Updates", subtitle: "New versions come from UU RemoteDroid's GitHub releases") {
            VStack(spacing: 9) {
                HStack {
                    Toggle(isOn: $autoUpdateChecks) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Check for updates automatically")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Theme.text)
                            Text("At launch and every six hours. Nothing installs without asking.")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.textFaint)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(Theme.accent)
                    Spacer()
                    LabelButton(symbol: "arrow.triangle.2.circlepath", label: "Check Now") {
                        dismiss()
                        UpdateService.shared.checkForUpdates(manual: true)
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 9))
                    Text("Updates are checked against their published SHA-256 and the UULabs signature before installing.")
                        .font(.system(size: 9))
                }
                .foregroundStyle(Theme.textFaint)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Text(model.configuration == draft ? "Settings are up to date" : "Stream changes restart active devices")
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.textFaint)
            Spacer()
            LabelButton(symbol: "xmark", label: "Cancel") {
                dismiss()
            }
            LabelButton(symbol: "checkmark", label: "Save", prominent: true) {
                let changed = model.configuration != draft
                if changed {
                    model.setConfiguration(draft)
                }
                dismiss()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.12))
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
    }

    private func settingsCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textFaint)
            }
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Theme.panel.opacity(0.72))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
        )
    }

    private func settingRow<Trailing: View>(
        title: String,
        detail: String,
        icon: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textFaint)
                .frame(width: 15)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textFaint)
            }
            Spacer()
            trailing()
        }
    }

    private func aboutRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.textMuted)
            Spacer()
            Text(value)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Theme.text)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
