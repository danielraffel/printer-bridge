import Foundation
import PrinterBridgeCore

enum PrinterBridgeCLI {
    static let usage = """
        Usage:
          PrinterBridgeCLI overview
          PrinterBridgeCLI hosts
          PrinterBridgeCLI roadmap
          PrinterBridgeCLI show-config
          PrinterBridgeCLI bridge-status
          PrinterBridgeCLI enable [printer-name]
          PrinterBridgeCLI disable
          PrinterBridgeCLI set-advertised-name <name>
          PrinterBridgeCLI clear-advertised-name
          PrinterBridgeCLI doctor [printer-name]
          PrinterBridgeCLI list-printers
          PrinterBridgeCLI inspect-printer <printer-name>
          PrinterBridgeCLI ipp-attributes <printer-name>
          PrinterBridgeCLI snapshot [printer-name]
          PrinterBridgeCLI list-services
          PrinterBridgeCLI smoke-test
        """

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "overview"
        let diagnostics = HostDiagnosticsService()
        let inventory = PrinterInventoryService()
        let attributeService = IPPPrinterAttributeService()
        let configurationStore = BridgeConfigurationStore()
        let statusService = BridgeStatusService(
            inventoryService: inventory,
            attributeService: attributeService
        )

        switch command {
        case "overview":
            print(ProjectDiagnostics.overviewText)
        case "hosts":
            print(ProjectDiagnostics.hostsText)
        case "roadmap":
            print(ProjectDiagnostics.roadmapText)
        case "show-config":
            do {
                let configuration = try configurationStore.load()
                print(renderConfiguration(configuration))
            } catch {
                fputs("Failed to load bridge configuration: \(error)\n", stderr)
                exit(1)
            }
        case "bridge-status":
            do {
                let configuration = try configurationStore.load()
                print(statusService.renderStatus(configuration: configuration))
            } catch {
                fputs("Failed to evaluate bridge status: \(error)\n", stderr)
                exit(1)
            }
        case "enable":
            do {
                var configuration = try configurationStore.load()
                let printerName = arguments.dropFirst().first ?? configuration.selectedQueueName ?? ProjectMetadata.primaryTargetPrinter
                configuration.selectedQueueName = printerName
                configuration.isEnabled = true
                try configurationStore.save(configuration)
                print(statusService.renderStatus(configuration: configuration))
            } catch {
                fputs("Failed to enable bridge: \(error)\n", stderr)
                exit(1)
            }
        case "disable":
            do {
                var configuration = try configurationStore.load()
                configuration.isEnabled = false
                try configurationStore.save(configuration)
                print(statusService.renderStatus(configuration: configuration))
            } catch {
                fputs("Failed to disable bridge: \(error)\n", stderr)
                exit(1)
            }
        case "set-advertised-name":
            let nameParts = Array(arguments.dropFirst())
            guard !nameParts.isEmpty else {
                fputs("set-advertised-name requires a value.\n\n\(usage)\n", stderr)
                exit(2)
            }

            do {
                var configuration = try configurationStore.load()
                configuration.advertisedNameOverride = nameParts.joined(separator: " ")
                try configurationStore.save(configuration)
                print(statusService.renderStatus(configuration: configuration))
            } catch {
                fputs("Failed to set advertised name: \(error)\n", stderr)
                exit(1)
            }
        case "clear-advertised-name":
            do {
                var configuration = try configurationStore.load()
                configuration.advertisedNameOverride = nil
                try configurationStore.save(configuration)
                print(statusService.renderStatus(configuration: configuration))
            } catch {
                fputs("Failed to clear advertised name: \(error)\n", stderr)
                exit(1)
            }
        case "doctor":
            let printerName = arguments.dropFirst().first ?? ProjectMetadata.primaryTargetPrinter
            let report = diagnostics.doctor(printerName: printerName)
            print(report.renderedText)
            exit(report.success ? 0 : 1)
        case "list-printers":
            print(inventory.renderQueueList())
        case "inspect-printer":
            guard let printerName = arguments.dropFirst().first, !printerName.isEmpty else {
                fputs("inspect-printer requires a printer name.\n\n\(usage)\n", stderr)
                exit(2)
            }

            let output = inventory.renderInspection(named: printerName)
            print(output)
            exit(output.contains("queue not found") ? 1 : 0)
        case "ipp-attributes":
            guard let printerName = arguments.dropFirst().first, !printerName.isEmpty else {
                fputs("ipp-attributes requires a printer name.\n\n\(usage)\n", stderr)
                exit(2)
            }

            let output = attributeService.renderAttributes(forQueueNamed: printerName)
            print(output)
            exit(output.contains("failed to read IPP attributes") ? 1 : 0)
        case "snapshot":
            let printerName = arguments.dropFirst().first ?? ProjectMetadata.primaryTargetPrinter
            print(inventory.renderSnapshot(preferredQueueName: printerName))
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

    static func renderConfiguration(_ configuration: BridgeConfiguration) -> String {
        var lines = [
            "PrinterBridge configuration",
            "",
            "Summary",
            "- enabled: \(configuration.isEnabled ? "yes" : "no")",
            "- exposure mode: \(configuration.exposureMode.rawValue)",
        ]

        if let selectedQueueName = configuration.selectedQueueName, !selectedQueueName.isEmpty {
            lines.append("- selected queue: \(selectedQueueName)")
        }

        if let advertisedNameOverride = configuration.advertisedNameOverride, !advertisedNameOverride.isEmpty {
            lines.append("- advertised name override: \(advertisedNameOverride)")
        }

        return lines.joined(separator: "\n")
    }
}

PrinterBridgeCLI.main()
