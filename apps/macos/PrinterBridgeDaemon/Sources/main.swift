import Dispatch
import Foundation
import PrinterBridgeCore

final class DaemonCoordinator {
    private let configurationStore: BridgeConfigurationStore
    private let statusService: BridgeStatusService
    private let runtimeService: BridgeRuntimeService
    private let queue = DispatchQueue(label: "com.danielraffel.printerbridge.daemon")
    private let timer: DispatchSourceTimer
    private let pollInterval: TimeInterval

    private var activeSession: BridgeRuntimeSession?
    private var activeAdvertisement: AirPrintAdvertisementPlan?
    private var lastStateSummary: String?

    init(
        configurationStore: BridgeConfigurationStore = BridgeConfigurationStore(),
        statusService: BridgeStatusService = BridgeStatusService(),
        runtimeService: BridgeRuntimeService = BridgeRuntimeService(),
        pollInterval: TimeInterval = 5
    ) {
        self.configurationStore = configurationStore
        self.statusService = statusService
        self.runtimeService = runtimeService
        self.pollInterval = pollInterval
        self.timer = DispatchSource.makeTimerSource(queue: queue)
    }

    func start() {
        timer.setEventHandler { [weak self] in
            self?.reconcile()
        }
        timer.schedule(deadline: .now(), repeating: pollInterval)
        timer.resume()
    }

    func stop() {
        timer.cancel()
        stopActiveSession()
    }

    private func reconcile() {
        do {
            var configuration = try configurationStore.load()
            if configuration.exposureMode != .proxy {
                configuration.exposureMode = .proxy
                try? configurationStore.save(configuration)
            }

            let snapshot = statusService.evaluate(configuration: configuration)
            emitStateTransitionIfNeeded(snapshot: snapshot)

            guard configuration.isEnabled, snapshot.isPublishable, let advertisement = snapshot.advertisement else {
                stopActiveSession()
                return
            }

            if let activeSession, activeSession.isRunning, activeAdvertisement == advertisement {
                return
            }

            stopActiveSession()
            activeSession = try runtimeService.start(advertisementPlan: advertisement) { chunk in
                let lines = chunk
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                for line in lines {
                    if line.hasPrefix("[proxy]") {
                        print(line)
                    } else {
                        print("[dns-sd] \(line)")
                    }
                }
            }
            activeAdvertisement = advertisement
            print("Publishing `\(advertisement.serviceName)` at \(advertisement.printerURI).")
        } catch {
            let summary = "Failed to load bridge configuration: \(error.localizedDescription)"
            if lastStateSummary != summary {
                fputs("\(summary)\n", stderr)
                lastStateSummary = summary
            }
            stopActiveSession()
        }
    }

    private func emitStateTransitionIfNeeded(snapshot: BridgeStatusSnapshot) {
        var components = [
            "state=\(snapshot.activationState.rawValue)",
            "enabled=\(snapshot.configuration.isEnabled ? "yes" : "no")",
            "publishable=\(snapshot.isPublishable ? "yes" : "no")",
        ]

        if let queueName = snapshot.configuration.selectedQueueName {
            components.append("queue=\(queueName)")
        }

        if let advertisement = snapshot.advertisement {
            components.append("endpoint=\(advertisement.printerURI)")
        }

        if !snapshot.message.isEmpty {
            components.append("message=\(snapshot.message)")
        }

        if let warning = snapshot.advertisement?.warnings.first {
            components.append("warning=\(warning)")
        }

        let summary = components.joined(separator: " ")
        guard summary != lastStateSummary else {
            return
        }

        print(summary)
        lastStateSummary = summary
    }

    private func stopActiveSession() {
        if let activeSession {
            _ = activeSession.stop()
        }
        activeSession = nil
        activeAdvertisement = nil
    }
}

enum PrinterBridgeDaemon {
    static func main() {
        let coordinator = DaemonCoordinator()
        coordinator.start()

        let signalMonitor = ProcessSignalMonitor {
            coordinator.stop()
            print("Stopped bridge runtime.")
            exit(0)
        }
        _ = signalMonitor

        dispatchMain()
    }
}

PrinterBridgeDaemon.main()
