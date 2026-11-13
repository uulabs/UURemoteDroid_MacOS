import SwiftUI
import AppKit

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
            WorkspaceView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.layoutMode == .single, model.showInspector {
                InspectorView()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .frame(minWidth: 1180, minHeight: 700)
        .background(WindowConfigurator())
        .preferredColorScheme(.dark)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 86)
                    .padding(.horizontal, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
                    .onTapGesture { model.toast = nil }
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.showInspector)
        .animation(.easeOut(duration: 0.2), value: model.layoutMode)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.toast?.id)
        .sheet(isPresented: $model.showSettings) {
            SettingsView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
        .task {
            model.startMonitoring()
            #if DEBUG
            if let raw = ProcessInfo.processInfo.environment["UU_WALL_AFTER"],
               let delay = Double(raw) {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                model.wallSerials = Set(model.readyDevices.map(\.serial))
                model.setLayout(.grid)
                print("[debug] switched to wall with \(model.wallSerials.count) devices")
            }
            if let raw = ProcessInfo.processInfo.environment["UU_REORDER_WALL_AFTER"],
               let delay = Double(raw) {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                let before = model.wallDevices.map(\.serial)
                if let first = before.first, let last = before.last, first != last {
                    model.moveWallDevice(first, toSlotOf: last)
                }
                print("[debug] wall order before=\(before) after=\(model.wallDevices.map(\.serial))")
            }
            #endif
        }
    }
}
