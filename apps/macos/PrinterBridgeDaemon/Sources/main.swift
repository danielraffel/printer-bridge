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

    private var activeSessions: [String: BridgeRuntimeSession] = [:]
    private var activeAdvertisements: [String: AirPrintAdvertisementPlan] = [:]
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
        stopAllSessions()
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

            let desiredAdvertisements = Dictionary(
                uniqueKeysWithValues: snapshot.publishableAdvertisements.map { ($0.backingQueueName, $0) }
            )
            let activeQueueNames = Set(activeSessions.keys)
            let desiredQueueNames = Set(desiredAdvertisements.keys)

            for queueName in activeQueueNames.subtracting(desiredQueueNames) {
                stopSession(forQueueNamed: queueName)
            }

            for (queueName, advertisement) in desiredAdvertisements {
                if let activeSession = activeSessions[queueName],
                   activeSession.isRunning,
                   activeAdvertisements[queueName] == advertisement {
                    continue
                }

                stopSession(forQueueNamed: queueName)

                let session = try runtimeService.start(advertisementPlan: advertisement) { chunk in
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

                activeSessions[queueName] = session
                activeAdvertisements[queueName] = advertisement
                print("Publishing `\(advertisement.serviceName)` at \(advertisement.printerURI).")
            }
        } catch {
            let summary = "Failed to load bridge configuration: \(error.localizedDescription)"
            if lastStateSummary != summary {
                fputs("\(summary)\n", stderr)
                lastStateSummary = summary
            }
            stopAllSessions()
        }
    }

    private func emitStateTransitionIfNeeded(snapshot: BridgeStatusSnapshot) {
        var components = [
            "focused-state=\(snapshot.activationState.rawValue)",
            "enabled=\(snapshot.enabledPrinterCount)",
            "live=\(snapshot.livePrinterCount)",
        ]

        if let queueName = snapshot.configuration.selectedQueueName {
            components.append("focused-queue=\(queueName)")
        }

        if !snapshot.publishableAdvertisements.isEmpty {
            let endpoints = snapshot.publishableAdvertisements
                .map(\.printerURI)
                .sorted()
                .joined(separator: ",")
            components.append("endpoints=\(endpoints)")
        }

        if !snapshot.message.isEmpty {
            components.append("message=\(snapshot.message)")
        }

        if let warning = snapshot.selectedPrinter?.advertisement?.warnings.first {
            components.append("warning=\(warning)")
        }

        let summary = components.joined(separator: " ")
        guard summary != lastStateSummary else {
            return
        }

        print(summary)
        lastStateSummary = summary
    }

    private func stopSession(forQueueNamed queueName: String) {
        if let activeSession = activeSessions.removeValue(forKey: queueName) {
            _ = activeSession.stop()
        }
        activeAdvertisements.removeValue(forKey: queueName)
    }

    private func stopAllSessions() {
        for queueName in Array(activeSessions.keys) {
            stopSession(forQueueNamed: queueName)
        }
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
