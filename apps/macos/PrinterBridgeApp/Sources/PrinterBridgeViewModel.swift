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
    private let backgroundAgentController: BackgroundAgentController
    private let statusService: BridgeStatusService

    private var activeSessions: [String: BridgeRuntimeSession] = [:]
    private var activeAdvertisements: [String: AirPrintAdvertisementPlan] = [:]
    private var refreshTask: Task<Void, Never>?
    private var jobsTask: Task<Void, Never>?
    private var backgroundSyncTask: Task<Void, Never>?
    private var hasSynchronizedBackgroundAgent = false

    init(
        configurationStore: BridgeConfigurationStore = BridgeConfigurationStore(),
        runtimeService: BridgeRuntimeService = BridgeRuntimeService(),
        backgroundAgentController: BackgroundAgentController = BackgroundAgentController(),
        statusService: BridgeStatusService = BridgeStatusService()
    ) {
        self.configurationStore = configurationStore
        self.runtimeService = runtimeService
        self.backgroundAgentController = backgroundAgentController
        self.statusService = statusService
    }

    var selectedQueueTitle: String {
        focusedPrinterStatus?.inspection?.detail.description
            ?? bridgeConfiguration.selectedQueueName.map(queueDisplayName(_:))
            ?? "No Printer Selected"
    }

    var currentAirPrintName: String {
        focusedPrinterStatus?.advertisement?.serviceName
            ?? focusedPrinterStatus?.configuration.advertisedNameOverride
            ?? selectedQueueTitle
    }

    var currentEndpointDescription: String {
        focusedPrinterStatus?.advertisement?.printerURI
            ?? publicationState.detail
    }

    var printerStatuses: [ManagedPrinterStatus] {
        bridgeStatus?.managedPrinters ?? []
    }

    var focusedPrinterStatus: ManagedPrinterStatus? {
        bridgeStatus?.selectedPrinter
    }

    var enabledPrinterCount: Int {
        bridgeStatus?.enabledPrinterCount ?? 0
    }

    var livePrinterCount: Int {
        bridgeStatus?.livePrinterCount ?? 0
    }

    var statusSummary: String {
        switch publicationState {
        case .inactive:
            if printerStatuses.isEmpty {
                return "Add a printer in System Settings to see it here."
            }
            return "Turn on AirPrint for the printers you want to share."
        case .waiting:
            if enabledPrinterCount > 0 {
                return "\(ProjectMetadata.appDisplayName) is still setting up one or more enabled printers."
            }
            return "Turn on AirPrint for the printers you want to share."
        case .advertising:
            if livePrinterCount == 1 {
                return "1 printer is ready to print from Apple devices on this network."
            }
            return "\(livePrinterCount) printers are ready to print from Apple devices on this network."
        case .failed:
            return "\(ProjectMetadata.appDisplayName) could not start sharing."
        }
    }

    var printerEnablementSummary: String {
        let totalPrinterCount = printerStatuses.count

        guard totalPrinterCount > 0 else {
            return "No printers are available for AirPrint."
        }

        guard enabledPrinterCount > 0 else {
            return "No printers are enabled for AirPrint."
        }

        guard enabledPrinterCount == totalPrinterCount else {
            return "\(enabledPrinterCount) of \(totalPrinterCount) printers are enabled for AirPrint."
        }

        if totalPrinterCount == 1 {
            return "All printers are enabled for AirPrint."
        }

        return "All \(totalPrinterCount) printers are enabled for AirPrint."
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

            configuration.ensureFocusedQueue(fallbackQueueName: configuration.selectedQueueName ?? ProjectMetadata.primaryTargetPrinter)

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
        bridgeConfiguration.setSelectedQueueName(queueName)
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

    func setPrinterEnabled(_ enabled: Bool, forQueueNamed queueName: String) {
        bridgeConfiguration.setEnabled(enabled, forQueueNamed: queueName)
        bridgeConfiguration.setSelectedQueueName(queueName)
        applyOptimisticStatus()
        persistConfiguration(
            message: enabled
                ? "AirPrint enabled for \(queueDisplayName(queueName))."
                : "AirPrint disabled for \(queueDisplayName(queueName)).",
            forceBackgroundSync: bridgeConfiguration.keepRunningInBackground && !hasSynchronizedBackgroundAgent
        )
    }

    func applyAdvertisedName() {
        let trimmedName = advertisedNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let selectedQueueName = bridgeConfiguration.selectedQueueName else {
            bridgeMessage = "Select a printer before setting a custom AirPrint name."
            return
        }
        bridgeConfiguration.setAdvertisedNameOverride(trimmedName.isEmpty ? nil : trimmedName, forQueueNamed: selectedQueueName)
        persistConfiguration(message: "AirPrint name updated.")
    }

    func resetAdvertisedName() {
        advertisedNameDraft = ""
        guard let selectedQueueName = bridgeConfiguration.selectedQueueName else {
            bridgeMessage = "Select a printer before resetting the AirPrint name."
            return
        }
        bridgeConfiguration.setAdvertisedNameOverride(nil, forQueueNamed: selectedQueueName)
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

        performJobsOperation(
            successMessage: "Canceled active jobs.",
            failureMessage: "Could not cancel active jobs."
        ) { [queueName = bridgeConfiguration.selectedQueueName] in
            PrintJobQueueService().cancelAllActiveJobs(forQueueNamed: queueName)
        }
    }

    func cancelJob(_ job: PrintJob) {
        performJobsOperation(
            successMessage: "Canceled \(job.id).",
            failureMessage: "Could not cancel \(job.id)."
        ) {
            PrintJobQueueService().cancelActiveJob(job)
        }
    }

    func clearRecentJobs() {
        guard !recentCompletedJobs.isEmpty else {
            jobsMessage = "No recent jobs to clear."
            return
        }

        guard jobSnapshot.activeJobs.isEmpty else {
            jobsMessage = "Clear Recent is only available when there are no active jobs."
            return
        }

        performJobsOperation(
            successMessage: "Cleared recent jobs.",
            failureMessage: "Could not clear recent jobs."
        ) { [queueName = bridgeConfiguration.selectedQueueName] in
            PrintJobQueueService().purgeAllJobs(forQueueNamed: queueName)
        }
    }

    func handleAppWillTerminate() {
        refreshTask?.cancel()
        jobsTask?.cancel()
        backgroundSyncTask?.cancel()
        stopActivePublication()
    }

    private func persistConfiguration(message: String, forceBackgroundSync: Bool = true) {
        refreshTask?.cancel()
        let configurationToSave = bridgeConfiguration
        let configURL = configurationStore.configURL
        bridgeMessage = message

        refreshTask = Task {
            do {
                let payload = try await Task.detached(priority: .userInitiated) {
                    var normalizedConfiguration = configurationToSave
                    normalizedConfiguration.exposureMode = .proxy
                    normalizedConfiguration.normalize()

                    let store = BridgeConfigurationStore(configURL: configURL)
                    try store.save(normalizedConfiguration)

                    return Self.buildRefreshPayload(configuration: normalizedConfiguration)
                }.value

                guard !Task.isCancelled else {
                    return
                }

                applyRefreshPayload(payload, reconcileBackground: forceBackgroundSync)
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                publicationState = .failed(error.localizedDescription)
                bridgeMessage = "Failed to save settings: \(error.localizedDescription)"
            }
        }
    }

    private func performJobsOperation(
        successMessage: String,
        failureMessage: String,
        operation: @escaping @Sendable () -> Bool
    ) {
        jobsTask?.cancel()
        jobsTask = Task {
            let succeeded = await Task.detached(priority: .utility, operation: operation).value

            guard !Task.isCancelled else {
                return
            }

            if succeeded {
                jobsMessage = successMessage
                reloadJobs()
            } else {
                jobsMessage = failureMessage
            }
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

            if reconcileBackground {
                if bridgeStatus.enabledPrinterCount == 0 {
                    publicationState = .inactive
                } else if bridgeStatus.livePrinterCount > 0 {
                    publicationState = .advertising(summaryEndpointDescription(for: bridgeStatus))
                } else {
                    let reason = bridgeStatus.selectedPrinter?.message ?? bridgeStatus.message
                    publicationState = .waiting(reason.isEmpty ? "An enabled printer is not ready yet." : reason)
                }
                scheduleBackgroundAgentReconcile(using: bridgeStatus)
                return
            }

            let backgroundState = backgroundAgentController.status()
            syncBackgroundPublication(using: bridgeStatus, backgroundState: backgroundState)
            return
        }

        if hasSynchronizedBackgroundAgent {
            _ = backgroundAgentController.disable()
            hasSynchronizedBackgroundAgent = false
        }

        reconcileForegroundPublications(using: bridgeStatus)
    }

    private func syncBackgroundPublication(
        using bridgeStatus: BridgeStatusSnapshot,
        backgroundState: BackgroundAgentState
    ) {
        guard bridgeStatus.enabledPrinterCount > 0 else {
            publicationState = .inactive
            return
        }

        guard bridgeStatus.livePrinterCount > 0 else {
            let reason = bridgeStatus.selectedPrinter?.message ?? bridgeStatus.message
            publicationState = .waiting(reason.isEmpty ? "An enabled printer is not ready yet." : reason)
            return
        }

        switch backgroundState {
        case .running, .loaded:
            publicationState = .advertising(summaryEndpointDescription(for: bridgeStatus))
        case .stopped:
            publicationState = .waiting("The background service is not running.")
        case .requiresApproval:
            publicationState = .waiting("Allow Printer Bridge in System Settings > General > Login Items to keep sharing in the background.")
        case let .failed(reason):
            publicationState = .failed(reason)
        }
    }

    private func reconcileForegroundPublications(using bridgeStatus: BridgeStatusSnapshot) {
        let desiredAdvertisements = Dictionary(
            uniqueKeysWithValues: bridgeStatus.publishableAdvertisements.map { ($0.backingQueueName, $0) }
        )
        let activeQueueNames = Set(activeSessions.keys)
        let desiredQueueNames = Set(desiredAdvertisements.keys)

        for queueName in activeQueueNames.subtracting(desiredQueueNames) {
            stopActivePublication(forQueueNamed: queueName)
        }

        for (queueName, advertisement) in desiredAdvertisements {
            if let activeSession = activeSessions[queueName],
               activeSession.isRunning,
               activeAdvertisements[queueName] == advertisement {
                continue
            }

            stopActivePublication(forQueueNamed: queueName)

            do {
                let session = try runtimeService.start(advertisementPlan: advertisement) { [weak self] chunk in
                    Task { @MainActor [weak self] in
                        self?.recordBonjourEvent(from: chunk)
                    }
                }
                activeSessions[queueName] = session
                activeAdvertisements[queueName] = advertisement
            } catch {
                publicationState = .failed(error.localizedDescription)
                bridgeMessage = "Failed to start AirPrint advertisement: \(error.localizedDescription)"
                return
            }
        }

        if bridgeStatus.enabledPrinterCount == 0 {
            publicationState = .inactive
        } else if bridgeStatus.livePrinterCount > 0 {
            publicationState = .advertising(summaryEndpointDescription(for: bridgeStatus))
        } else {
            let reason = bridgeStatus.selectedPrinter?.message ?? bridgeStatus.message
            publicationState = .waiting(reason.isEmpty ? "An enabled printer is not ready yet." : reason)
        }
    }

    private func stopActivePublication(forQueueNamed queueName: String) {
        if let activeSession = activeSessions.removeValue(forKey: queueName) {
            _ = activeSession.stop()
        }
        activeAdvertisements.removeValue(forKey: queueName)
    }

    private func stopActivePublication() {
        for queueName in Array(activeSessions.keys) {
            stopActivePublication(forQueueNamed: queueName)
        }
        lastBonjourEvent = nil
    }

    private func summaryEndpointDescription(for bridgeStatus: BridgeStatusSnapshot) -> String {
        let liveCount = bridgeStatus.livePrinterCount
        if liveCount <= 1 {
            return bridgeStatus.selectedPrinter?.advertisement?.printerURI
                ?? bridgeStatus.publishableAdvertisements.first?.printerURI
                ?? "AirPrint is live."
        }

        return "\(liveCount) printers are live."
    }

    private func scheduleBackgroundAgentReconcile(using bridgeStatus: BridgeStatusSnapshot) {
        backgroundSyncTask?.cancel()
        let forceRestart = hasSynchronizedBackgroundAgent

        backgroundSyncTask = Task {
            let backgroundState = await Task.detached(priority: .utility) {
                do {
                    return try BackgroundAgentController().ensureInstalled(forceRestart: forceRestart)
                } catch {
                    return .failed(error.localizedDescription)
                }
            }.value

            guard !Task.isCancelled else {
                return
            }

            if backgroundState == .running || backgroundState == .loaded {
                hasSynchronizedBackgroundAgent = true
            }

            if case let .failed(reason) = backgroundState {
                bridgeMessage = reason
            }

            syncBackgroundPublication(using: bridgeStatus, backgroundState: backgroundState)
        }
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

    private func applyOptimisticStatus() {
        bridgeConfiguration.exposureMode = .proxy
        bridgeConfiguration.normalize()

        let snapshot = statusService.evaluate(configuration: bridgeConfiguration)
        bridgeStatus = snapshot

        if snapshot.enabledPrinterCount == 0 {
            publicationState = .inactive
            return
        }

        if snapshot.livePrinterCount > 0 {
            publicationState = .advertising(summaryEndpointDescription(for: snapshot))
            return
        }

        let reason = snapshot.selectedPrinter?.message ?? snapshot.message
        publicationState = .waiting(reason.isEmpty ? "An enabled printer is not ready yet." : reason)
    }

    nonisolated private static func buildRefreshPayload(configuration: BridgeConfiguration) -> RefreshPayload {
        let inventoryService = PrinterInventoryService()
        let statusService = BridgeStatusService()
        let jobQueueService = PrintJobQueueService()

        var workingConfiguration = configuration
        workingConfiguration.normalize()
        var inventorySnapshot = inventoryService.snapshot(preferredQueueName: workingConfiguration.selectedQueueName)

        if workingConfiguration.selectedQueueName == nil, let firstQueueName = inventorySnapshot.queues.first?.name {
            workingConfiguration.setSelectedQueueName(firstQueueName)
            inventorySnapshot = inventoryService.snapshot(preferredQueueName: firstQueueName)
        } else {
            workingConfiguration.ensureFocusedQueue(fallbackQueueName: inventorySnapshot.queues.first?.name)
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
