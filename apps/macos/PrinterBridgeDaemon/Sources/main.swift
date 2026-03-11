import Foundation
import PrinterBridgeCore

enum PrinterBridgeDaemon {
    static func main() {
        let configurationStore = BridgeConfigurationStore()
        let statusService = BridgeStatusService()
        let publisher = BonjourAdvertisementService()

        do {
            let configuration = try configurationStore.load()
            let snapshot = statusService.evaluate(configuration: configuration)
            print(statusService.renderStatus(configuration: configuration))

            guard configuration.isEnabled else {
                return
            }

            guard snapshot.isPublishable, let advertisement = snapshot.advertisement else {
                fputs("Bridge is enabled but not publishable yet.\n", stderr)
                exit(1)
            }

            let session = try publisher.publish(advertisement) { chunk in
                let lines = chunk
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                for line in lines {
                    print("[dns-sd] \(line)")
                }
            }

            let signalMonitor = ProcessSignalMonitor {
                let terminationStatus = session.stop()
                print("Stopped Bonjour publication (dns-sd exit code \(terminationStatus)).")
                exit(0)
            }
            _ = signalMonitor

            print("Publishing `\(advertisement.serviceName)` until the daemon is terminated.")
            dispatchMain()
        } catch {
            fputs("Failed to load bridge configuration: \(error)\n", stderr)
            exit(1)
        }
    }
}

PrinterBridgeDaemon.main()
