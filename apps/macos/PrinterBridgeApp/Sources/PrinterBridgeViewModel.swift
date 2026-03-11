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
                return "Needs Review"
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

    private struct RefreshPayload: Sendable {
        let configuration: BridgeConfiguration
        let inventorySnapshot: PrinterInventorySnapshot
        let bridgeStatus: BridgeStatusSnapshot
        let jobSnapshot: PrintJobQueueSnapshot
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
    private let runtimeService: BridgeRuntimeService
    private let jobQueueService: PrintJobQueueService
    private let backgroundAgentController: BackgroundAgentController

    private var activeSession: BridgeRuntimeSession?
    private var activeAdvertisement: AirPrintAdvertisementPlan?
    private var refreshTask: Task<Void, Never>?
    private var jobsTask: Task<Void, Never>?
    private var hasSynchronizedBackgroundAgent = false

    init(
        configurationStore: BridgeConfigurationStore = BridgeConfigurationStore(),
        runtimeService: BridgeRuntimeService = BridgeRuntimeService(),
        jobQueueService: PrintJobQueueService = PrintJobQueueService(),
        backgroundAgentController: BackgroundAgentController = BackgroundAgentController()
    ) {
        self.configurationStore = configurationStore
        self.runtimeService = runtimeService
        self.jobQueueService = jobQueueService
        self.backgroundAgentController = backgroundAgentController
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
            return bridgeConfiguration.keepRunningInBackground
                ? "PrinterBridge is ready to run in the background when AirPrint is enabled."
                : "AirPrint is off."
        case .waiting:
            return "PrinterBridge needs more information before it can share this printer."
        case .advertising:
            return bridgeConfiguration.keepRunningInBackground
                ? "Ready to print from Apple devices even after this window closes."
                : "Ready to print from Apple devices on this network."
        case .failed:
            return "PrinterBridge could not start sharing."
        }
    }

    var statusDetail: String? {
        switch publicationState {
        case .advertising, .inactive:
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

    func loadBridgeState(forceBackgroundSync: Bool = false) {
        refreshTask?.cancel()

        do {
            var configuration = try configurationStore.load()
            if configuration.exposureMode != .proxy {
                configuration.exposureMode = .proxy
                try? configurationStore.save(configuration)
            }

            advertisedNameDraft = configuration.advertisedNameOverride ?? ""

            let shouldSyncBackground = forceBackgroundSync || (configuration.keepRunningInBackground && !hasSynchronizedBackgroundAgent)
            refreshTask = Task {
                let payload = await Task.detached(priority: .userInitiated) {
                    Self.buildRefreshPayload(configuration: configuration)
                }.value

                guard !Task.isCancelled else {
                    return
                }

                applyRefreshPayload(payload, reconcileBackground: shouldSyncBackground)
            }
        } catch {
            stopActivePublication()
            inventorySnapshot = PrinterInventoryService().snapshot(preferredQueueName: ProjectMetadata.primaryTargetPrinter)
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

    func updateKeepRunningInBackground(_ enabled: Bool) {
        bridgeConfiguration.keepRunningInBackground = enabled
        persistConfiguration(
            message: enabled
                ? "Background sharing enabled."
                : "Background sharing disabled."
        )
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
        jobsTask?.cancel()
        let queueName = bridgeConfiguration.selectedQueueName
        jobsTask = Task {
            let snapshot = await Task.detached(priority: .utility) {
                PrintJobQueueService().snapshot(forQueueNamed: queueName)
            }.value

            guard !Task.isCancelled else {
                return
            }

            jobSnapshot = snapshot
            jobsMessage = nil
        }
    }

    func cancelActiveJobs() {
        guard !jobSnapshot.activeJobs.isEmpty else {
            jobsMessage = "No active jobs to cancel."
            return
        }

        let queueName = bridgeConfiguration.selectedQueueName
        jobsTask?.cancel()
        jobsTask = Task {
            let canceled = await Task.detached(priority: .utility) {
                PrintJobQueueService().cancelAllActiveJobs(forQueueNamed: queueName)
            }.value

            guard !Task.isCancelled else {
                return
            }

            if canceled {
                jobsMessage = "Canceled active jobs."
                reloadJobs()
            } else {
                jobsMessage = "Could not cancel active jobs."
            }
        }
    }

    func handleAppWillTerminate() {
        refreshTask?.cancel()
        jobsTask?.cancel()
        stopActivePublication()
    }

    private func persistConfiguration(message: String) {
        do {
            bridgeConfiguration.exposureMode = .proxy
            try configurationStore.save(bridgeConfiguration)
            bridgeMessage = message
            loadBridgeState(forceBackgroundSync: true)
        } catch {
            publicationState = .failed(error.localizedDescription)
            bridgeMessage = "Failed to save settings: \(error.localizedDescription)"
        }
    }

    private func applyRefreshPayload(_ payload: RefreshPayload, reconcileBackground: Bool) {
        let previousQueueName = bridgeConfiguration.selectedQueueName

        bridgeConfiguration = payload.configuration
        advertisedNameDraft = bridgeConfiguration.advertisedNameOverride ?? ""
        inventorySnapshot = payload.inventorySnapshot
        bridgeStatus = payload.bridgeStatus
        jobSnapshot = payload.jobSnapshot

        if bridgeConfiguration.selectedQueueName != previousQueueName {
            try? configurationStore.save(bridgeConfiguration)
        }

        syncPublication(reconcileBackground: reconcileBackground)
    }

    private func syncPublication(reconcileBackground: Bool) {
        guard let bridgeStatus else {
            stopActivePublication()
            publicationState = .failed("Bridge status is unavailable.")
            return
        }

        if bridgeConfiguration.keepRunningInBackground {
            stopActivePublication()

            let backgroundState: BackgroundAgentState
            if reconcileBackground {
                do {
                    backgroundState = try backgroundAgentController.ensureInstalled(
                        configURL: configurationStore.configURL,
                        forceRestart: hasSynchronizedBackgroundAgent
                    )
                    hasSynchronizedBackgroundAgent = true
                } catch {
                    publicationState = .failed(error.localizedDescription)
                    bridgeMessage = error.localizedDescription
                    return
                }
            } else {
                backgroundState = backgroundAgentController.status()
            }

            syncBackgroundPublication(using: bridgeStatus, backgroundState: backgroundState)
            return
        }

        if hasSynchronizedBackgroundAgent {
            _ = backgroundAgentController.disable()
            hasSynchronizedBackgroundAgent = false
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

    private func syncBackgroundPublication(
        using bridgeStatus: BridgeStatusSnapshot,
        backgroundState: BackgroundAgentState
    ) {
        guard bridgeConfiguration.isEnabled else {
            publicationState = .inactive
            return
        }

        guard bridgeStatus.isPublishable, let advertisement = bridgeStatus.advertisement else {
            let reason = bridgeStatus.advertisement?.warnings.first ?? bridgeStatus.message
            publicationState = .waiting(reason.isEmpty ? "The selected printer is not ready yet." : reason)
            return
        }

        switch backgroundState {
        case .running, .loaded:
            publicationState = .advertising(advertisement.printerURI)
        case .stopped:
            publicationState = .waiting("The background service is starting.")
        case let .failed(reason):
            publicationState = .failed(reason)
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
        if reason.contains("not shared yet") {
            return "This build uses a local AirPrint proxy. Refresh the app after updating if you still see an old printer-sharing warning."
        }

        return reason
    }

    nonisolated private static func buildRefreshPayload(configuration: BridgeConfiguration) -> RefreshPayload {
        let inventoryService = PrinterInventoryService()
        let statusService = BridgeStatusService()
        let jobQueueService = PrintJobQueueService()

        var workingConfiguration = configuration
        var inventorySnapshot = inventoryService.snapshot(preferredQueueName: workingConfiguration.selectedQueueName)

        if workingConfiguration.selectedQueueName == nil, let firstQueueName = inventorySnapshot.queues.first?.name {
            workingConfiguration.selectedQueueName = firstQueueName
            inventorySnapshot = inventoryService.snapshot(preferredQueueName: firstQueueName)
        }

        let bridgeStatus = statusService.evaluate(configuration: workingConfiguration)
        let jobSnapshot = jobQueueService.snapshot(forQueueNamed: workingConfiguration.selectedQueueName)

        return RefreshPayload(
            configuration: workingConfiguration,
            inventorySnapshot: inventorySnapshot,
            bridgeStatus: bridgeStatus,
            jobSnapshot: jobSnapshot
        )
    }
}
