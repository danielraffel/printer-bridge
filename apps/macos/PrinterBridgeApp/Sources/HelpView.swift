import PrinterBridgeCore
import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(ProjectMetadata.appDisplayName)
                    .font(.title2.weight(.semibold))

                helpSection(
                    "What It Does",
                    [
                        "Turn on AirPrint sharing for printers already installed on this Mac.",
                        "Keep older printers useful longer instead of turning working equipment into e-waste.",
                        "Run in the background so you do not need to keep the window open.",
                    ]
                )

                helpSection(
                    "Printer States",
                    [
                        "`Live` means this printer is being advertised over AirPrint right now.",
                        "`Off` means Printer Bridge is not sharing that printer.",
                        "`Needs Review` means the printer is installed, but Printer Bridge still needs something to line up before it can share it reliably.",
                        "`Unavailable` means the queue is not currently available on this Mac.",
                    ]
                )

                helpSection(
                    "Jobs",
                    [
                        "`Refresh` reloads the current queue from CUPS.",
                        "`Cancel Active` stops jobs that are still in progress at the Mac queue.",
                        "`Clear Recent` removes completed history for the selected queue when there are no active jobs.",
                    ]
                )

                helpSection(
                    "Advanced",
                    [
                        "`Keep sharing in the background` installs and uses the bundled background service so AirPrint stays available after the window closes.",
                        "`AirPrint name` lets you publish a friendlier printer name than the raw CUPS queue name.",
                        "`Endpoint` shows the IPP address currently being advertised for the selected printer.",
                    ]
                )
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 500, height: 560)
    }

    private func helpSection(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
