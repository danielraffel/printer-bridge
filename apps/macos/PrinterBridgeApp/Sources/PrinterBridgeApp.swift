import AppKit
import PrinterBridgeCore
import SwiftUI

@main
struct PrinterBridgeApp: App {
    @StateObject private var model = PrinterBridgeViewModel()

    var body: some Scene {
        WindowGroup(ProjectMetadata.appDisplayName) {
            ContentView(model: model)
                .frame(width: 560, height: 470)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.loadBridgeState()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.handleAppWillTerminate()
                }
        }
        .windowResizability(.contentSize)
        .commands {
            PrinterBridgeCommands()
        }

        Window("\(ProjectMetadata.appDisplayName) Help", id: "help") {
            HelpView()
                .frame(width: 500, height: 560)
        }
        .windowResizability(.contentSize)
    }
}

private struct PrinterBridgeCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("\(ProjectMetadata.appDisplayName) Help") {
                openWindow(id: "help")
            }
            .keyboardShortcut("?", modifiers: [.command])
        }
    }
}
