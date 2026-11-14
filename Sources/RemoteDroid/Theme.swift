import SwiftUI
import AppKit

enum Theme {
    static let background = Color(hex: 0x080B10)
    static let backgroundLift = Color(hex: 0x0C1118)
    static let sidebar = Color(hex: 0x0A0E14)
    static let panel = Color(hex: 0x101720)
    static let panelRaised = Color(hex: 0x151E29)
    static let panelHover = Color(hex: 0x182330)
    static let stroke = Color.white.opacity(0.075)
    static let strokeStrong = Color.white.opacity(0.13)
    static let text = Color(hex: 0xF2F6FA)
    static let textMuted = Color(hex: 0x8C9AAC)
    static let textFaint = Color(hex: 0x5F6C7D)
    static let accent = Color(hex: 0x5BE3C7)
    static let accentSoft = Color(hex: 0x32BFA8)
    static let indigo = Color(hex: 0x8494FF)
    static let blue = Color(hex: 0x65A8FF)
    static let success = Color(hex: 0x5EE49A)
    static let warning = Color(hex: 0xF5C45A)
    static let danger = Color(hex: 0xFF7A8C)
    static let violet = Color(hex: 0xB58CFF)

    static let accentGradient = LinearGradient(
        colors: [accent, blue],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let brandGradient = LinearGradient(
        colors: [Color(hex: 0x67F5D6), Color(hex: 0x6F9CFF), Color(hex: 0xA681FF)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}

struct AppMark: View {
    var size: CGFloat = 36
    var body: some View {
        // The bundled app icon, so the sidebar matches the Dock.
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct StatusDot: View {
    var color: Color
    var pulsing: Bool = false
    @State private var expanded = false

    var body: some View {
        ZStack {
            if pulsing {
                Circle()
                    .fill(color.opacity(0.28))
                    .frame(width: expanded ? 15 : 7, height: expanded ? 15 : 7)
                    .blur(radius: 1)
                    .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: expanded)
            }
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.7), radius: 4)
        }
        .frame(width: 15, height: 15)
        .onAppear { if pulsing { expanded = true } }
    }
}

struct SectionLabel: View {
    var text: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(text.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(Theme.textFaint)
            Spacer(minLength: 0)
            trailing
        }
    }
}

struct Pill: View {
    var icon: String? = nil
    var text: String
    var color: Color = Theme.textMuted
    var background: Color = Color.white.opacity(0.05)
    var monospaced: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8.5, weight: .semibold))
            }
            Text(text)
                .font(monospaced ? Theme.mono(9.5, weight: .medium) : .system(size: 9.5, weight: .semibold))
                .tracking(monospaced ? 0 : 0.4)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(
            Capsule(style: .continuous)
                .fill(background)
                .overlay(Capsule(style: .continuous).stroke(color.opacity(0.16), lineWidth: 0.6))
        )
    }
}

struct IconButton: View {
    var symbol: String
    var help: String
    var active: Bool = false
    var tint: Color = Theme.textMuted
    var size: CGFloat = 30
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(active ? Theme.accent : (hovering ? Theme.text : tint))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(active ? Theme.accent.opacity(0.10) : (hovering ? Color.white.opacity(0.055) : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(active ? Theme.accent.opacity(0.20) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct LabelButton: View {
    var symbol: String
    var label: String
    var prominent: Bool = false
    var disabled: Bool = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(prominent ? Color(hex: 0x06100E) : (disabled ? Theme.textFaint : Theme.text))
            .padding(.horizontal, 12)
            .frame(height: 31)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent ? Theme.accent : (hovering ? Color.white.opacity(0.075) : Color.white.opacity(0.045)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(prominent ? Color.white.opacity(0.16) : Theme.stroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
    }
}

struct ModeSwitcher: View {
    @Binding var mode: AppModel.LayoutMode
    var body: some View {
        HStack(spacing: 2) {
            segment(.single, icon: "rectangle.portrait", help: "Single device")
            segment(.grid, icon: "rectangle.grid.2x2", help: "All devices")
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.22))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
        )
    }

    private func segment(_ value: AppModel.LayoutMode, icon: String, help: String) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { mode = value }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(mode == value ? Theme.text : Theme.textFaint)
                .frame(width: 34, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .fill(mode == value ? Color.white.opacity(0.10) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct DottedBackdrop: View {
    var spacing: CGFloat = 24
    var dotColor: Color = Color.white.opacity(0.055)
    var body: some View {
        Canvas { context, size in
            let columns = Int(size.width / spacing) + 2
            let rows = Int(size.height / spacing) + 2
            for column in 0..<columns {
                for row in 0..<rows {
                    let point = CGPoint(x: CGFloat(column) * spacing, y: CGFloat(row) * spacing)
                    let rect = CGRect(x: point.x, y: point.y, width: 1.4, height: 1.4)
                    context.fill(Path(ellipseIn: rect), with: .color(dotColor))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(Theme.background)
            window.styleMask.insert(.fullSizeContentView)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ToastView: View {
    var toast: AppModel.Toast
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(toast.isError ? Theme.danger : Theme.accent)
                .frame(width: 24, height: 24)
                .background(Circle().fill((toast.isError ? Theme.danger : Theme.accent).opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let detail = toast.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(hex: 0x121A24).opacity(0.97))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: Color.black.opacity(0.4), radius: 18, y: 8)
        )
        .frame(maxWidth: 420)
    }
}

struct ProgressBar: View {
    var value: Double?
    var tint: Color = Theme.accent
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.075))
                if let value {
                    Capsule()
                        .fill(LinearGradient(colors: [tint, Theme.blue], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(3, proxy.size.width * min(max(value, 0), 1)))
                } else {
                    Capsule()
                        .fill(tint.opacity(0.45))
                        .frame(width: proxy.size.width * 0.35)
                        .blur(radius: 0.5)
                }
            }
        }
        .frame(height: 3)
    }
}

struct Spinner: View {
    @State private var spinning = false
    var color: Color = Theme.accent
    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.72)
            .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: 13, height: 13)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}
