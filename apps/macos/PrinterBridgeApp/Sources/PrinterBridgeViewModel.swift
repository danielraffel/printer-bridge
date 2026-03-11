import Combine
import Foundation
import PrinterBridgeCore

@MainActor
final class PrinterBridgeViewModel: ObservableObject {
    enum PublicationState: Equatable {
        case inactive
        case waiting(String)
        case advertising(String)
        case failed(String)

        var title: String {
            switch self {
            case .inactive:
                return "Off"
            case .waiting:
                return "Needs Setup"
            case .advertising:
                return "Live"
            case .failed:
                return "Error"
            }
        }

        var detail: String {
            switch self {
            case .inactive:
                return "AirPrint is not being advertised."
            case let .waiting(reason):
                return reason
            case let .advertising(endpoint):
                return endpoint
            case let .failed(reason):
                return reason
            }
        }

        var requiresAttention: Bool {
            switch self {
            case .waiting, .failed:
                return true
            case .inactive, .advertising:
                return false
            }
        }
    }

    @Published var inventorySnapshot: PrinterInventorySnapshot?
    @Published var bridgeConfiguration = BridgeConfiguration()
    @Published var bridgeStatus: BridgeStatusSnapshot?
    @Published var jobSnapshot = PrintJobQueueSnapshot(queueName: nil, activeJobs: [], completedJobs: [])
    @Published var advertisedNameDraft = ""
    @Published var bridgeMessage: String?
    @Published var jobsMessage: String?
    @Published var publicationState: PublicationState = .inactive
    @Published var lastBonjourEvent: String?

    private let configurationStore: BridgeConfigurationStore
    private let inventoryService: PrinterInventoryService
    private let statusService: BridgeStatusService
    private let runtimeService: BridgeRuntimeService
    private let jobQueueService: PrintJobQueueService

    private var activeSession: BridgeRuntimeSession?
    private var activeAdvertisement: AirPrintAdvertisementPlan?

    init(
        configurationStore: BridgeConfigurationStore = BridgeConfigurationStore(),
        inventoryService: PrinterInventoryService = PrinterInventoryService(),
        statusService: BridgeStatusService = BridgeStatusService(),
        runtimeService: BridgeRuntimeService = BridgeRuntimeService(),
        jobQueueService: PrintJobQueueService = PrintJobQueueService()
    ) {
        self.configurationStore = configurationStore
        self.inventoryService = inventoryService
        self.statusService = statusService
        self.runtimeService = runtimeService
        self.jobQueueService = jobQueueService
    }

    var selectedQueueTitle: String {
        bridgeStatus?.selectedQueue?.detail.description
            ?? bridgeConfiguration.selectedQueueName.map(queueDisplayName(_:))
            ?? "No Printer Selected"
    }

    var currentAirPrintName: String {
        bridgeStatus?.advertisement?.serviceName
            ?? bridgeConfiguration.advertisedNameOverride
            ?? selectedQueueTitle
    }

    var currentEndpointDescription: String {
        bridgeStatus?.advertisement?.printerURI
            ?? publicationState.detail
    }

    var statusSummary: String {
        switch publicationState {
        case .inactive:
            return "AirPrint is off."
        case .waiting:
            return "Finish the required setup before sharing this printer."
        case .advertising:
            return "Ready to print from Apple devices on this network."
        case .failed:
            return "PrinterBridge could not start sharing."
        }
    }

    var statusDetail: String? {
        switch publicationState {
        case .advertising:
            return nil
        case .inactive:
            return nil
        case let .waiting(reason):
            return friendlySetupText(for: reason)
        case let .failed(reason):
            return reason
        }
    }

    var recentCompletedJobs: [PrintJob] {
        Array(jobSnapshot.completedJobs.prefix(20))
    }

    func loadBridgeState() {
        do {
            bridgeConfiguration = try configurationStore.load()
            migrateToProxyIfNeeded()
            advertisedNameDraft = bridgeConfiguration.advertisedNameOverride ?? ""
            refreshState(message: nil, jobsMessage: nil)
        } catch {
            stopActivePublication()
            inventorySnapshot = inventoryService.snapshot(preferredQueueName: ProjectMetadata.primaryTargetPrinter)
            bridgeStatus = nil
            jobSnapshot = PrintJobQueueSnapshot(queueName: nil, activeJobs: [], completedJobs: [])
            publicationState = .failed(error.localizedDescription)
            bridgeMessage = "Failed to load bridge state: \(error.localizedDescription)"
        }
    }

    func updateSelectedQueue(_ queueName: String?) {
        bridgeConfiguration.selectedQueueName = queueName
        persistConfiguration(message: "Selected printer updated.")
    }

    func toggleBridgeEnabled() {
        bridgeConfiguration.isEnabled.toggle()
        persistConfiguration(
            message: bridgeConfiguration.isEnabled
                ? "AirPrint enabled."
                : "AirPrint disabled."
        )
    }

    func applyAdvertisedName() {
        let trimmedName = advertisedNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        bridgeConfiguration.advertisedNameOverride = trimmedName.isEmpty ? nil : trimmedName
        persistConfiguration(message: "AirPrint name updated.")
    }

    func resetAdvertisedName() {
        advertisedNameDraft = ""
        bridgeConfiguration.advertisedNameOverride = nil
        persistConfiguration(message: "AirPrint name reset.")
    }

    func reloadJobs() {
        jobSnapshot = jobQueueService.snapshot(forQueueNamed: bridgeConfiguration.selectedQueueName)
        jobsMessage = nil
    }

    func cancelActiveJobs() {
        guard !jobSnapshot.activeJobs.isEmpty else {
            jobsMessage = "No active jobs to cancel."
            return
        }

        if jobQueueService.cancelAllActiveJobs(forQueueNamed: bridgeConfiguration.selectedQueueName) {
            reloadJobs()
            jobsMessage = "Canceled active jobs."
        } else {
            jobsMessage = "Could not cancel active jobs."
        }
    }

    func handleAppWillTerminate() {
        stopActivePublication()
    }

    private func persistConfiguration(message: String) {
        do {
            bridgeConfiguration.exposureMode = .proxy
            try configurationStore.save(bridgeConfiguration)
            refreshState(message: message, jobsMessage: nil)
        } catch {
            publicationState = .failed(error.localizedDescription)
            bridgeMessage = "Failed to save settings: \(error.localizedDescription)"
        }
    }

    private func refreshState(message: String?, jobsMessage: String?) {
        var snapshot = inventoryService.snapshot(preferredQueueName: bridgeConfiguration.selectedQueueName)
        if bridgeConfiguration.selectedQueueName == nil, let firstQueueName = snapshot.queues.first?.name {
            bridgeConfiguration.selectedQueueName = firstQueueName
            snapshot = inventoryService.snapshot(preferredQueueName: firstQueueName)
        }

        inventorySnapshot = snapshot
        bridgeStatus = statusService.evaluate(configuration: bridgeConfiguration)
        bridgeMessage = message
        self.jobsMessage = jobsMessage
        reloadJobs()
        syncPublication()
    }

    private func syncPublication() {
        guard let bridgeStatus else {
            stopActivePublication()
            publicationState = .failed("Bridge status is unavailable.")
            return
        }

        guard bridgeStatus.isPublishable, let advertisement = bridgeStatus.advertisement else {
            stopActivePublication()
            if bridgeConfiguration.isEnabled {
                let reason = bridgeStatus.advertisement?.warnings.first ?? bridgeStatus.message
                publicationState = .waiting(reason.isEmpty ? "The selected printer is not ready yet." : reason)
            } else {
                publicationState = .inactive
            }
            return
        }

        if let activeSession, activeSession.isRunning, activeAdvertisement == advertisement {
            publicationState = .advertising(advertisement.printerURI)
            return
        }

        stopActivePublication()

        do {
            let session = try runtimeService.start(advertisementPlan: advertisement) { [weak self] chunk in
                Task { @MainActor [weak self] in
                    self?.recordBonjourEvent(from: chunk)
                }
            }
            activeSession = session
            activeAdvertisement = advertisement
            publicationState = .advertising(advertisement.printerURI)
        } catch {
            publicationState = .failed(error.localizedDescription)
            bridgeMessage = "Failed to start AirPrint advertisement: \(error.localizedDescription)"
        }
    }

    private func stopActivePublication() {
        if let activeSession {
            _ = activeSession.stop()
        }
        activeSession = nil
        activeAdvertisement = nil
        lastBonjourEvent = nil
    }

    private func recordBonjourEvent(from chunk: String) {
        let lastLine = chunk
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last

        if let lastLine, !lastLine.isEmpty {
            lastBonjourEvent = lastLine
        }
    }

    private func queueDisplayName(_ queueName: String) -> String {
        queueName.replacingOccurrences(of: "_", with: " ")
    }

    private func friendlySetupText(for reason: String) -> String {
        if reason.contains("not shared yet"), let queueName = bridgeConfiguration.selectedQueueName {
            return "Turn on “Share this printer on the network” in System Settings > Printers & Scanners > \(queueDisplayName(queueName))."
        }

        return reason
    }

    private func migrateToProxyIfNeeded() {
        guard bridgeConfiguration.exposureMode != .proxy else {
            return
        }

        bridgeConfiguration.exposureMode = .proxy
        try? configurationStore.save(bridgeConfiguration)
    }
}
