import PrinterBridgeCore
import SwiftUI

struct ContentView: View {
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
}

#Preview {
    ContentView()
}
