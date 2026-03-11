import PrinterBridgeCore
import SwiftUI

struct ContentView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case printers = "Printers"
        case jobs = "Jobs"

        var id: String { rawValue }
    }

    @ObservedObject var model: PrinterBridgeViewModel

    @State private var selectedTab: Tab = .printers

    var body: some View {
        TabView(selection: $selectedTab) {
            printersTab
                .tabItem {
                    Label(Tab.printers.rawValue, systemImage: "printer")
                }
                .tag(Tab.printers)

            jobsTab
                .tabItem {
                    Label(Tab.jobs.rawValue, systemImage: "list.bullet.rectangle")
                }
                .tag(Tab.jobs)
        }
        .frame(width: 560, height: 470)
        .task {
            model.loadBridgeState(forceBackgroundSync: true)
        }
    }

    private var printersTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusCard

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Printer", selection: selectedQueueBinding) {
                        if let inventorySnapshot = model.inventorySnapshot, !inventorySnapshot.queues.isEmpty {
                            ForEach(inventorySnapshot.queues) { queue in
                                Text(queueDisplayName(queue.name)).tag(Optional(queue.name))
                            }
                        } else {
                            Text("No printers found").tag(Optional<String>.none)
                        }
                    }
                    .pickerStyle(.menu)

                    HStack(spacing: 10) {
                        Button(model.bridgeConfiguration.isEnabled ? "Disable AirPrint" : "Enable AirPrint") {
                            model.toggleBridgeEnabled()
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.inventorySnapshot?.queues.isEmpty ?? true)

                        Button("Refresh") {
                            model.loadBridgeState()
                        }

                        Spacer()
                    }
                }
            }

            DisclosureGroup("Advanced") {
                advancedSection
                    .padding(.top, 12)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var jobsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Print Queue")
                        .font(.headline)

                    if let queueName = model.bridgeConfiguration.selectedQueueName {
                        Text(queueDisplayName(queueName))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button("Refresh") {
                    model.reloadJobs()
                }

                Button("Cancel Active") {
                    model.cancelActiveJobs()
                }
                .disabled(model.jobSnapshot.activeJobs.isEmpty)

                Button("Clear Recent") {
                    model.clearRecentJobs()
                }
                .disabled(model.recentCompletedJobs.isEmpty || !model.jobSnapshot.activeJobs.isEmpty)
            }

            List {
                Section("Active") {
                    if model.jobSnapshot.activeJobs.isEmpty {
                        emptyJobsRow("No active jobs.")
                    } else {
                        ForEach(model.jobSnapshot.activeJobs) { job in
                            jobRow(job, stateLabel: "Printing") {
                                model.cancelJob(job)
                            }
                        }
                    }
                }

                Section("Recent") {
                    if model.recentCompletedJobs.isEmpty {
                        emptyJobsRow("No recent jobs.")
                    } else {
                        ForEach(model.recentCompletedJobs) { job in
                            jobRow(job, stateLabel: "Completed")
                        }
                    }
                }
            }
            .listStyle(.inset)

            if let jobsMessage = model.jobsMessage, !jobsMessage.isEmpty {
                Text(jobsMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var statusCard: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.selectedQueueTitle)
                        .font(.title3)
                        .fontWeight(.semibold)

                    Text(model.statusSummary)
                        .foregroundStyle(.secondary)

                    if let statusDetail = model.statusDetail {
                        Text(statusDetail)
                            .font(.footnote)
                            .foregroundStyle(statusDetailColor)
                    }
                }

                Spacer()

                Text(model.publicationState.title)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(statusTint.opacity(0.16))
                    .foregroundStyle(statusTint)
                    .clipShape(Capsule())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(
                "Keep sharing in the background",
                isOn: Binding(
                    get: { model.bridgeConfiguration.keepRunningInBackground },
                    set: { model.updateKeepRunningInBackground($0) }
                )
            )

            Text("When enabled, \(ProjectMetadata.appDisplayName) keeps AirPrint available after you close the window.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextField("Use printer name", text: $model.advertisedNameDraft)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Button("Apply Name") {
                    model.applyAdvertisedName()
                }

                Button("Reset Name") {
                    model.resetAdvertisedName()
                }
                .disabled((model.bridgeConfiguration.advertisedNameOverride ?? "").isEmpty && model.advertisedNameDraft.isEmpty)

                Spacer()
            }

            detailRow(title: "AirPrint name", value: model.currentAirPrintName)
            detailRow(title: "Endpoint", value: model.currentEndpointDescription, monospace: true)

            if let bridgeMessage = model.bridgeMessage, !bridgeMessage.isEmpty {
                Text(bridgeMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let lastBonjourEvent = model.lastBonjourEvent, !lastBonjourEvent.isEmpty {
                detailRow(title: "Last Bonjour event", value: lastBonjourEvent, monospace: true)
            }

            if let warnings = model.bridgeStatus?.advertisement?.warnings, !warnings.isEmpty {
                Divider()
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusTint: Color {
        switch model.publicationState {
        case .inactive:
            return .secondary
        case .waiting:
            return .orange
        case .advertising:
            return .green
        case .failed:
            return .red
        }
    }

    private var statusDetailColor: Color {
        switch model.publicationState {
        case .failed:
            return .red
        case .waiting:
            return .orange
        case .inactive, .advertising:
            return .secondary
        }
    }

    private var selectedQueueBinding: Binding<String?> {
        Binding(
            get: { model.bridgeConfiguration.selectedQueueName },
            set: { model.updateSelectedQueue($0) }
        )
    }

    @ViewBuilder
    private func jobRow(_ job: PrintJob, stateLabel: String, action: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: stateLabel == "Printing" ? "printer.fill" : "checkmark.circle.fill")
                .foregroundStyle(stateLabel == "Printing" ? .blue : .green)

            VStack(alignment: .leading, spacing: 3) {
                Text(job.id)
                    .font(.subheadline.weight(.medium))
                Text("\(job.owner) • \(job.submittedAt)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(stateLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let sizeBytes = job.sizeBytes {
                    Text(byteCountFormatter.string(fromByteCount: Int64(sizeBytes)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let action {
                Button(action: action) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Cancel job")
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func emptyJobsRow(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }

    @ViewBuilder
    private func detailRow(title: String, value: String, monospace: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospace ? .system(.footnote, design: .monospaced) : .body)
                .textSelection(.enabled)
        }
    }

    private func queueDisplayName(_ queueName: String) -> String {
        queueName.replacingOccurrences(of: "_", with: " ")
    }

    private var byteCountFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }
}

#Preview {
    ContentView(model: PrinterBridgeViewModel())
}
