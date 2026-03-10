import PrinterBridgeCore
import SwiftUI

struct ContentView: View {
    @State private var inventorySnapshot: PrinterInventorySnapshot?

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
            inventorySnapshot = PrinterInventoryService().snapshot(preferredQueueName: ProjectMetadata.primaryTargetPrinter)
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
}

#Preview {
    ContentView()
}
