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
    }
}
