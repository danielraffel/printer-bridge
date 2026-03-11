import Foundation
import PrinterBridgeCore

enum PrinterBridgeCLI {
    struct AdvertiseOptions {
        let printerName: String?
        let duration: TimeInterval
    }

    static let usage = """
        Usage:
          PrinterBridgeCLI overview
          PrinterBridgeCLI hosts
          PrinterBridgeCLI roadmap
          PrinterBridgeCLI show-config
          PrinterBridgeCLI bridge-status
          PrinterBridgeCLI advertise [printer-name] [--duration seconds]
          PrinterBridgeCLI advertise-test-service [service-name] [--duration seconds] [--port port]
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
        let runtimeService = BridgeRuntimeService()
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
        case "advertise":
            guard let options = parseAdvertiseOptions(Array(arguments.dropFirst())) else {
                fputs("advertise accepts an optional printer name and `--duration <seconds>`.\n\n\(usage)\n", stderr)
                exit(2)
            }

            do {
                let storedConfiguration = try configurationStore.load()
                let configuration = advertiseConfiguration(from: storedConfiguration, printerNameOverride: options.printerName)
                let snapshot = statusService.evaluate(configuration: configuration)
                print(statusService.renderStatus(configuration: configuration))

                guard snapshot.isPublishable, let advertisement = snapshot.advertisement else {
                    fputs("\nThe selected queue is not publishable yet.\n", stderr)
                    exit(1)
                }

                try runAdvertisement(advertisement, duration: options.duration, runtimeService: runtimeService)
            } catch {
                fputs("Failed to advertise bridge service: \(error)\n", stderr)
                exit(1)
            }
        case "advertise-test-service":
            guard let options = parseTestAdvertiseOptions(Array(arguments.dropFirst())) else {
                fputs("advertise-test-service accepts an optional service name plus `--duration <seconds>` and `--port <port>`.\n\n\(usage)\n", stderr)
                exit(2)
            }

            let hostName = BridgeStatusService.defaultHostName()
            let serviceName = options.serviceName ?? "PrinterBridge Test"
            let resourcePath = "printers/test"
            let advertisement = AirPrintAdvertisementPlan(
                serviceName: serviceName,
                hostName: hostName,
                port: options.port,
                resourcePath: "/\(resourcePath)",
                printerURI: "ipp://\(hostName):\(options.port)/\(resourcePath)",
                backingQueueName: "test",
                exposureMode: .directCUPS,
                txtRecords: [
                    .init(key: "txtvers", value: "1"),
                    .init(key: "qtotal", value: "1"),
                    .init(key: "rp", value: resourcePath),
                    .init(key: "ty", value: serviceName),
                    .init(key: "product", value: "(PrinterBridge Test Service)"),
                    .init(key: "pdl", value: "application/pdf,image/urf,image/pwg-raster"),
                    .init(key: "URF", value: "W8,RS300-600"),
                ],
                warnings: ["Development-only synthetic AirPrint advertisement."]
            )

            do {
                print("Synthetic AirPrint advertisement")
                print("- service name: \(advertisement.serviceName)")
                print("- printer URI: \(advertisement.printerURI)")
                print("- port: \(advertisement.port)")
                print("- warning: \(advertisement.warnings.joined(separator: " "))")
                try runAdvertisement(advertisement, duration: options.duration, runtimeService: runtimeService)
            } catch {
                fputs("Failed to advertise synthetic service: \(error)\n", stderr)
                exit(1)
            }
        case "enable":
            do {
                var configuration = try configurationStore.load()
                let printerName = arguments.dropFirst().first ?? configuration.selectedQueueName ?? ProjectMetadata.primaryTargetPrinter
                configuration.selectedQueueName = printerName
                configuration.isEnabled = true
                configuration.exposureMode = .proxy
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

    static func parseAdvertiseOptions(_ arguments: [String]) -> AdvertiseOptions? {
        parseAdvertiseOptions(arguments, allowPort: false).map { AdvertiseOptions(printerName: $0.serviceName, duration: $0.duration) }
    }

    static func parseTestAdvertiseOptions(_ arguments: [String]) -> TestAdvertiseOptions? {
        parseAdvertiseOptions(arguments, allowPort: true)
    }

    static func parseAdvertiseOptions(
        _ arguments: [String],
        allowPort: Bool
    ) -> TestAdvertiseOptions? {
        var printerName: String?
        var duration: TimeInterval = 30
        var port = 8631
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--duration" {
                guard index + 1 < arguments.count, let parsedDuration = TimeInterval(arguments[index + 1]), parsedDuration >= 0 else {
                    return nil
                }

                duration = parsedDuration
                index += 2
                continue
            }

            if argument == "--port" {
                guard allowPort, index + 1 < arguments.count, let parsedPort = Int(arguments[index + 1]), parsedPort > 0, parsedPort < 65536 else {
                    return nil
                }

                port = parsedPort
                index += 2
                continue
            }

            guard printerName == nil else {
                return nil
            }

            printerName = argument
            index += 1
        }

        return TestAdvertiseOptions(serviceName: printerName, duration: duration, port: port)
    }

    static func advertiseConfiguration(
        from configuration: BridgeConfiguration,
        printerNameOverride: String?
    ) -> BridgeConfiguration {
        var configuration = configuration
        configuration.isEnabled = true
        configuration.selectedQueueName = printerNameOverride ?? configuration.selectedQueueName ?? ProjectMetadata.primaryTargetPrinter
        return configuration
    }

    static func renderPublisherOutput(_ chunk: String) {
        let lines = chunk
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines {
            if line.hasPrefix("[proxy]") {
                print(line)
            } else {
                print("[dns-sd] \(line)")
            }
        }
    }

    static func runAdvertisement(
        _ advertisement: AirPrintAdvertisementPlan,
        duration: TimeInterval,
        runtimeService: BridgeRuntimeService
    ) throws {
        let session = try runtimeService.start(advertisementPlan: advertisement) { chunk in
            renderPublisherOutput(chunk)
        }
        defer {
            _ = session.stop()
        }

        let durationDescription = duration == 0 ? "until interrupted" : "\(Int(duration.rounded())) seconds"
        print("\nAdvertising `\(advertisement.serviceName)` for \(durationDescription).")

        var shouldStop = false
        let signalMonitor = ProcessSignalMonitor {
            shouldStop = true
        }
        _ = signalMonitor

        if duration == 0 {
            while !shouldStop && session.isRunning {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
            }
        } else {
            let deadline = Date().addingTimeInterval(duration)
            while !shouldStop && session.isRunning && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
            }
        }

        let terminationStatus = session.stop()
        print("Stopped bridge runtime (dns-sd exit code \(terminationStatus)).")
    }
}

extension PrinterBridgeCLI {
    struct TestAdvertiseOptions {
        let serviceName: String?
        let duration: TimeInterval
        let port: Int
    }
}

PrinterBridgeCLI.main()
