import PrinterBridgeCore
import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(ProjectMetadata.appDisplayName)
                .font(.title2.weight(.semibold))

            Text(ProjectMetadata.appStoreName)
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Open source software from Generous Corp to keep working printers useful longer.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                Link("View Source on GitHub", destination: URL(string: ProjectMetadata.repositoryURL)!)
                Link("Report a Bug", destination: URL(string: ProjectMetadata.bugReportURL)!)
                Link("Request a Feature", destination: URL(string: ProjectMetadata.featureRequestURL)!)
            }
            .font(.body)

            Text("PRs are welcome. Printer Bridge is designed to work with printers that already print successfully from this Mac.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(20)
        .frame(width: 420, height: 260, alignment: .topLeading)
    }
}
