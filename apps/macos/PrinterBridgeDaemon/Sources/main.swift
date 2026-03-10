import Foundation
import PrinterBridgeCore

enum PrinterBridgeDaemon {
    static func main() {
        let configurationStore = BridgeConfigurationStore()
        let statusService = BridgeStatusService()

        do {
            let configuration = try configurationStore.load()
            print(statusService.renderStatus(configuration: configuration))
        } catch {
            fputs("Failed to load bridge configuration: \(error)\n", stderr)
            exit(1)
        }
    }
}

PrinterBridgeDaemon.main()
