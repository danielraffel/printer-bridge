import AppKit
import PrinterBridgeCore
import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)

            VStack(spacing: 6) {
                Text(ProjectMetadata.appDisplayName)
                    .font(.title.weight(.semibold))

                Text(ProjectMetadata.appStoreName)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            Text("Let's keep more hardware from becoming unnecessary e-waste.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 10) {
                Link("View Source on GitHub", destination: URL(string: ProjectMetadata.repositoryURL)!)
                Link("Report a Bug", destination: URL(string: ProjectMetadata.bugReportURL)!)
                Link("Request a Feature", destination: URL(string: ProjectMetadata.featureRequestURL)!)
            }
            .font(.body)

            Divider()

            HStack(spacing: 18) {
                Link("Privacy Policy", destination: URL(string: ProjectMetadata.privacyURL)!)
                Link("Terms", destination: URL(string: ProjectMetadata.termsURL)!)
            }
            .font(.footnote)

            Text("Printer Bridge is designed to work with printers that already print successfully from this Mac. Tested with Brother HL-2170W series. Other printers are likely to work if they already print normally through macOS.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 470, height: 440)
    }
}
