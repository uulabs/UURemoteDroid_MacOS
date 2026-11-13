import SwiftUI
import AppKit

@main
struct RemoteDroidApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Send Files…") {
                    model.chooseFiles(installOnly: false)
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model.selectedDevice?.isReady != true)

                Button("Install APK…") {
                    model.chooseFiles(installOnly: true)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.selectedDevice?.isReady != true)

                Button("Take Screenshot") {
                    model.captureScreenshot()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model.selectedDevice?.isReady != true)
            }

            CommandMenu("Device") {
                Button("Back") { model.activeSession?.pressBack() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Home") { model.activeSession?.pressHome() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Recent Apps") { model.activeSession?.pressAppSwitch() }
                    .keyboardShortcut("\t", modifiers: [.command, .shift])
                Divider()
                Button("Volume Up") { model.activeSession?.pressVolumeUp() }
                Button("Volume Down") { model.activeSession?.pressVolumeDown() }
                Button("Power / Lock") { model.activeSession?.pressPower() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Rotate Display") { model.activeSession?.rotate() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Open Notifications") { model.activeSession?.expandNotifications() }
                Divider()
                Button("Restart Stream") {
                    if let serial = model.selectedSerial {
                        model.retrySession(for: serial)
                    }
                }
                Button("Disconnect") {
                    if let serial = model.selectedSerial {
                        model.closeSession(for: serial)
                    }
                }
            }

            CommandMenu("View") {
                Button("Single Device") {
                    model.setLayout(.single)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Device Wall") {
                    model.setLayout(.grid)
                }
                .keyboardShortcut("2", modifiers: .command)

                Divider()

                Button(model.showInspector ? "Hide Inspector" : "Show Inspector") {
                    model.showInspector.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model.layoutMode != .single)

                Divider()

                Button("Refresh Devices") {
                    model.refreshNow()
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Connect All Devices") {
                    model.setLayout(.grid)
                    model.connectAll()
                }
                .disabled(model.readyDevices.count < 2)
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    model.showSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        setvbuf(stdout, nil, _IONBF, 0)
        #endif
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        DebugCapture.scheduleIfNeeded()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}
