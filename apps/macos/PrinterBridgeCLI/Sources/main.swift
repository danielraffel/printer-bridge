import Foundation
import PrinterBridgeCore

enum PrinterBridgeCLI {
    static let usage = """
        Usage:
          PrinterBridgeCLI overview
          PrinterBridgeCLI hosts
          PrinterBridgeCLI roadmap
          PrinterBridgeCLI doctor [printer-name]
          PrinterBridgeCLI list-printers
          PrinterBridgeCLI inspect-printer <printer-name>
          PrinterBridgeCLI list-services
          PrinterBridgeCLI smoke-test
        """

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "overview"
        let diagnostics = HostDiagnosticsService()

        switch command {
        case "overview":
            print(ProjectDiagnostics.overviewText)
        case "hosts":
            print(ProjectDiagnostics.hostsText)
        case "roadmap":
            print(ProjectDiagnostics.roadmapText)
        case "doctor":
            let printerName = arguments.dropFirst().first ?? ProjectMetadata.primaryTargetPrinter
            let report = diagnostics.doctor(printerName: printerName)
            print(report.renderedText)
            exit(report.success ? 0 : 1)
        case "list-printers":
            print(diagnostics.listPrintersReport().renderedText)
        case "inspect-printer":
            guard let printerName = arguments.dropFirst().first, !printerName.isEmpty else {
                fputs("inspect-printer requires a printer name.\n\n\(usage)\n", stderr)
                exit(2)
            }

            let report = diagnostics.inspectPrinterReport(named: printerName)
            print(report.renderedText)
            exit(report.success ? 0 : 1)
        case "list-services":
            let report = diagnostics.listServicesReport()
            print(report.renderedText)
            exit(report.success ? 0 : 1)
        case "smoke-test":
            let result = ProjectDiagnostics.smokeTest()
            print(result.output)
            exit(result.success ? 0 : 1)
        case "help", "--help", "-h":
            print(usage)
        default:
            fputs("Unknown command: \(command)\n", stderr)
            fputs("\n\(usage)\n", stderr)
            exit(2)
        }
    }
}

PrinterBridgeCLI.main()
