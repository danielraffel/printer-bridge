import AppKit
import PrinterBridgeCore
import SwiftUI

@main
struct PrinterBridgeApp: App {
    @AppStorage(AppAppearanceMode.storageKey) private var appearanceModeRaw = AppAppearanceMode.system.rawValue
    @StateObject private var model = PrinterBridgeViewModel()
    @State private var appearanceRefreshToken = UUID()

    private var appearanceMode: AppAppearanceMode {
        AppAppearanceMode(storedValue: appearanceModeRaw)
    }

    var body: some Scene {
        WindowGroup(ProjectMetadata.appDisplayName) {
            ContentView(
                model: model,
                appearanceMode: Binding(
                    get: { appearanceMode },
                    set: { appearanceModeRaw = $0.rawValue }
                ),
                appearanceRefreshToken: appearanceRefreshToken
            )
                .frame(width: 560, height: 470)
                .preferredColorScheme(appearanceMode.colorScheme)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.loadBridgeState()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.handleAppWillTerminate()
                }
                .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))) { _ in
                    guard appearanceMode == .system else {
                        return
                    }
                    refreshAppearance()
                }
                .onChange(of: appearanceModeRaw) { _, _ in
                    refreshAppearance()
                }
                .task {
                    refreshAppearance(rebuildTabView: false)
                }
        }
        .windowResizability(.contentSize)
        .commands {
            PrinterBridgeCommands()
        }

        Window("\(ProjectMetadata.appDisplayName) Help", id: "help") {
            HelpView()
                .frame(width: 500, height: 560)
                .preferredColorScheme(appearanceMode.colorScheme)
        }
        .windowResizability(.contentSize)

        Window("About \(ProjectMetadata.appDisplayName)", id: "about") {
            AboutView()
                .preferredColorScheme(appearanceMode.colorScheme)
        }
        .windowResizability(.contentSize)
    }

    private func refreshAppearance(rebuildTabView: Bool = true) {
        WindowAppearanceController.apply(appearanceMode)
        if rebuildTabView {
            appearanceRefreshToken = UUID()
        }
    }
}

private struct PrinterBridgeCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(ProjectMetadata.appDisplayName)") {
                openWindow(id: "about")
            }
        }

        CommandGroup(replacing: .help) {
            Button("\(ProjectMetadata.appDisplayName) Help") {
                openWindow(id: "help")
            }
            .keyboardShortcut("?", modifiers: [.command])
        }
    }
}
