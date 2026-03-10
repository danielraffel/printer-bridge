import PrinterBridgeCore
import SwiftUI

struct ContentView: View {
    @State private var inventorySnapshot: PrinterInventorySnapshot?
    @State private var bridgeConfiguration = BridgeConfiguration()
    @State private var bridgeStatus: BridgeStatusSnapshot?
    @State private var advertisedNameDraft = ""
    @State private var bridgeMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                GroupBox("Current Focus") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("macOS-first AirPrint bridge for legacy printers")
                            .font(.headline)
                        Text("The current scaffold is optimized for development on Apple Silicon and deployment to the Intel verification host alias `macmini`.")
                            .foregroundStyle(.secondary)
                        Text("The development CLI stays separate from the default app artifact so remote SSH diagnostics do not expand the end-user release surface.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Host Topology") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(DevelopmentTopology.hosts) { host in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(host.name)
                                    .font(.headline)
                                Text(host.description)
                                    .foregroundStyle(.secondary)
                                if let access = host.accessCommand {
                                    Text(access)
                                        .font(.system(.body, design: .monospaced))
                                }
                            }
                            if host.id != DevelopmentTopology.hosts.last?.id {
                                Divider()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Queue Inventory") {
                    inventorySection
                }
                GroupBox("Bridge Control") {
                    bridgeControlSection
                }
                GroupBox("Next Steps") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(ProjectRoadmap.nearTerm, id: \.self) { item in
                            Label(item, systemImage: "checklist")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            loadBridgeState()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ProjectMetadata.productName)
                .font(.largeTitle)
                .fontWeight(.semibold)
            Text("Universal macOS scaffold for bridging legacy CUPS printers into AirPrint-visible services.")
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Label("Support floor \(ProjectMetadata.minimumSupportedMacOS)", systemImage: "macwindow")
                Label("Verification alias \(ProjectMetadata.verificationHostAlias)", systemImage: "network")
            }
            .font(.system(.body, design: .monospaced))
        }
    }

    @ViewBuilder
    private var inventorySection: some View {
        if let inventorySnapshot {
            VStack(alignment: .leading, spacing: 12) {
                Text("Detected queues: \(inventorySnapshot.queues.count)")
                    .font(.headline)

                ForEach(inventorySnapshot.queues) { queue in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(queue.name)
                            .font(.headline)
                        Text("Status: \(queue.status)")
                            .foregroundStyle(.secondary)
                        if let stateDetail = queue.stateDetail, !stateDetail.isEmpty {
                            Text(stateDetail)
                                .foregroundStyle(.secondary)
                        }
                        if let deviceURI = queue.deviceURI, !deviceURI.isEmpty {
                            Text(deviceURI)
                                .font(.system(.footnote, design: .monospaced))
                        }
                    }

                    if queue.id != inventorySnapshot.queues.last?.id {
                        Divider()
                    }
                }

                if let preferredInspection = inventorySnapshot.preferredInspection {
                    Divider()
                    Text("Preferred Queue")
                        .font(.headline)
                    Text("\(preferredInspection.summary.name) is \(preferredInspection.suitability.rawValue)")
                    Text(preferredInspection.suitabilityReason)
                        .foregroundStyle(.secondary)
                    Text("Options exposed: \(preferredInspection.options.count)")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ProgressView("Inspecting local printers…")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var bridgeControlSection: some View {
        if let inventorySnapshot {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Selected Printer", selection: selectedQueueBinding) {
                    ForEach(inventorySnapshot.queues) { queue in
                        Text(queue.name).tag(Optional(queue.name))
                    }
                }
                .pickerStyle(.menu)

                TextField("Advertised AirPrint Name", text: $advertisedNameDraft, prompt: Text("Use printer description by default"))

                HStack(spacing: 12) {
                    Button(bridgeConfiguration.isEnabled ? "Disable AirPrint" : "Enable AirPrint") {
                        toggleBridgeEnabled()
                    }

                    Button("Apply Name") {
                        applyAdvertisedName()
                    }
                    .disabled(inventorySnapshot.queues.isEmpty)

                    Button("Reload") {
                        loadBridgeState()
                    }
                }

                if let bridgeStatus {
                    Divider()
                    Text("State: \(bridgeStatus.activationState.rawValue)")
                        .font(.headline)
                    Text(bridgeStatus.message)
                        .foregroundStyle(.secondary)

                    if let advertisement = bridgeStatus.advertisement {
                        Text("Service: \(advertisement.serviceName)")
                        Text(advertisement.printerURI)
                            .font(.system(.footnote, design: .monospaced))

                        if !advertisement.warnings.isEmpty {
                            Divider()
                            ForEach(advertisement.warnings, id: \.self) { warning in
                                Text(warning)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let bridgeMessage, !bridgeMessage.isEmpty {
                    Divider()
                    Text(bridgeMessage)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ProgressView("Loading bridge configuration…")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var selectedQueueBinding: Binding<String?> {
        Binding(
            get: { bridgeConfiguration.selectedQueueName },
            set: { newValue in
                bridgeConfiguration.selectedQueueName = newValue
                persistConfiguration(message: "Selected printer updated.")
            }
        )
    }

    private func loadBridgeState() {
        let store = BridgeConfigurationStore()
        let inventoryService = PrinterInventoryService()
        let statusService = BridgeStatusService(inventoryService: inventoryService)

        do {
            var configuration = try store.load()
            let snapshot = inventoryService.snapshot(preferredQueueName: configuration.selectedQueueName)

            if configuration.selectedQueueName == nil {
                configuration.selectedQueueName = snapshot.queues.first?.name
            }

            bridgeConfiguration = configuration
            advertisedNameDraft = configuration.advertisedNameOverride ?? ""
            inventorySnapshot = snapshot
            bridgeStatus = statusService.evaluate(configuration: configuration)
            bridgeMessage = nil
        } catch {
            bridgeMessage = "Failed to load bridge state: \(error.localizedDescription)"
            inventorySnapshot = inventoryService.snapshot(preferredQueueName: ProjectMetadata.primaryTargetPrinter)
            bridgeStatus = nil
        }
    }

    private func toggleBridgeEnabled() {
        bridgeConfiguration.isEnabled.toggle()
        persistConfiguration(
            message: bridgeConfiguration.isEnabled
                ? "Bridge enabled for \(bridgeConfiguration.selectedQueueName ?? "the selected queue")."
                : "Bridge disabled."
        )
    }

    private func applyAdvertisedName() {
        bridgeConfiguration.advertisedNameOverride = advertisedNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : advertisedNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        persistConfiguration(message: "Advertised name updated.")
    }

    private func persistConfiguration(message: String) {
        let store = BridgeConfigurationStore()
        let inventoryService = PrinterInventoryService()
        let statusService = BridgeStatusService(inventoryService: inventoryService)

        do {
            try store.save(bridgeConfiguration)
            inventorySnapshot = inventoryService.snapshot(preferredQueueName: bridgeConfiguration.selectedQueueName)
            bridgeStatus = statusService.evaluate(configuration: bridgeConfiguration)
            bridgeMessage = message
        } catch {
            bridgeMessage = "Failed to save bridge configuration: \(error.localizedDescription)"
        }
    }
}

#Preview {
    ContentView()
}
