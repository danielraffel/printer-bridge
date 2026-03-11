import Testing
@testable import PrinterBridgeCore

@Test
func bridgeStatusUsesOverrideAndDirectCUPSPlan() {
    let runner = InventoryStubCommandRunner { executable, arguments in
        let command = ([executable] + arguments).joined(separator: " ")

        switch command {
        case "/usr/bin/lpstat -p":
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: "printer Brother_HL_2170W_series is idle.  enabled since Wed Aug 13 12:11:45 2025",
                standardError: ""
            )
        case "/usr/bin/lpstat -v":
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: "device for Brother_HL_2170W_series: dnssd://Brother.local./?bidi",
                standardError: ""
            )
        case "/usr/bin/lpstat -l -p Brother_HL_2170W_series":
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: """
                printer Brother_HL_2170W_series is idle.  enabled since Wed Aug 13 12:11:45 2025
                \tDescription: Brother HL-2170W series
                \tConnection: direct
                """,
                standardError: ""
            )
        case "/usr/bin/lpoptions -p Brother_HL_2170W_series -l":
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: """
                PageSize/Media Size: *Letter Legal A4
                Resolution/Resolution: *600dpi 1200dpi
                """,
                standardError: ""
            )
        case "/usr/bin/ipptool -tv ipp://localhost:631/printers/Brother_HL_2170W_series /usr/share/cups/ipptool/get-printer-attributes.test":
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: """
                "/usr/share/cups/ipptool/get-printer-attributes.test":
                    Get-Printer-Attributes:
                        attributes-charset (charset) = utf-8
                    Get printer attributes using get-printer-attributes                  [PASS]
                        printer-is-shared (boolean) = true
                        printer-uri-supported (uri) = ipp://localhost:631/printers/Brother_HL_2170W_series
                        printer-info (textWithoutLanguage) = Brother HL-2170W series
                        printer-make-and-model (textWithoutLanguage) = Brother HL-2170W series CUPS
                        color-supported (boolean) = false
                        document-format-supported (1setOf mimeMediaType) = application/pdf,image/pwg-raster,image/urf
                        printer-resolution-supported (1setOf resolution) = 300dpi,600dpi
                        sides-supported (keyword) = one-sided
                """,
                standardError: ""
            )
        default:
            return CommandResult(executable: executable, arguments: arguments, exitCode: 1, standardOutput: "", standardError: "unexpected command")
        }
    }

    let inventoryService = PrinterInventoryService(runner: runner)
    let attributeService = IPPPrinterAttributeService(runner: runner)
    let statusService = BridgeStatusService(
        inventoryService: inventoryService,
        attributeService: attributeService,
        hostNameProvider: { "test-host.local" }
    )
    let configuration = BridgeConfiguration(
        isEnabled: true,
        selectedQueueName: "Brother_HL_2170W_series",
        advertisedNameOverride: "Hallway Brother",
        exposureMode: .directCUPS
    )

    let snapshot = statusService.evaluate(configuration: configuration)

    #expect(snapshot.activationState == .ready)
    #expect(snapshot.advertisement?.serviceName == "Hallway Brother")
    #expect(snapshot.advertisement?.printerURI == "ipp://test-host.local:631/printers/Brother_HL_2170W_series")
    #expect(snapshot.advertisement?.txtRecords.contains(where: { $0.key == "pdl" && $0.value == "application/pdf,image/urf,image/pwg-raster" }) == true)
    #expect(snapshot.advertisement?.txtRecords.contains(where: { $0.key == "URF" && $0.value == "W8,RS300-600" }) == true)
    #expect(snapshot.advertisement?.warnings.isEmpty == true)
}

@Test
func preferredBonjourHostNameAvoidsNonLocalFQDNWhenBonjourNameExists() {
    let result = BridgeStatusService.preferredBonjourHostName(
        localHostName: "Daniels-Mac-mini-5",
        hostCurrentName: "daniels-old-mac-mini.tail2001.ts.net",
        processHostName: "daniels-old-mac-mini.tail2001.ts.net"
    )

    #expect(result == "Daniels-Mac-mini-5.local")
}

@Test
func bridgeStatusUsesHostDisplayNameWhenNoOverrideIsSet() {
    let runner = InventoryStubCommandRunner { executable, arguments in
        let command = ([executable] + arguments).joined(separator: " ")

        switch command {
        case "/usr/bin/lpstat -p":
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: "printer Brother_HL_2170W_series is idle.  enabled since Wed Aug 13 12:11:45 2025",
                standardError: ""
            )
        case "/usr/bin/lpstat -v":
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: "device for Brother_HL_2170W_series: dnssd://Brother.local./?bidi",
                standardError: ""
            )
        case "/usr/bin/lpstat -l -p Brother_HL_2170W_series":
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: """
                printer Brother_HL_2170W_series is idle.  enabled since Wed Aug 13 12:11:45 2025
                \tDescription: Brother HL-2170W series
                \tConnection: direct
                """,
                standardError: ""
            )
        case "/usr/bin/lpoptions -p Brother_HL_2170W_series -l":
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: "Resolution/Resolution: *600dpi 1200dpi",
                standardError: ""
            )
        case "/usr/bin/ipptool -tv ipp://localhost:631/printers/Brother_HL_2170W_series /usr/share/cups/ipptool/get-printer-attributes.test":
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: """
                "/usr/share/cups/ipptool/get-printer-attributes.test":
                    Get-Printer-Attributes:
                        attributes-charset (charset) = utf-8
                    Get printer attributes using get-printer-attributes                  [PASS]
                        printer-is-shared (boolean) = true
                        printer-info (textWithoutLanguage) = Brother HL-2170W series
                        printer-make-and-model (textWithoutLanguage) = Brother HL-2170W series CUPS
                        document-format-supported (1setOf mimeMediaType) = application/pdf,image/pwg-raster,image/urf
                        printer-resolution-supported (1setOf resolution) = 600dpi
                """,
                standardError: ""
            )
        default:
            return CommandResult(executable: executable, arguments: arguments, exitCode: 1, standardOutput: "", standardError: "unexpected command")
        }
    }

    let inventoryService = PrinterInventoryService(runner: runner)
    let attributeService = IPPPrinterAttributeService(runner: runner)
    let statusService = BridgeStatusService(
        inventoryService: inventoryService,
        attributeService: attributeService,
        hostNameProvider: { "test-host.local" }
    )
    let configuration = BridgeConfiguration(
        isEnabled: true,
        selectedQueueName: "Brother_HL_2170W_series",
        advertisedNameOverride: nil,
        exposureMode: .directCUPS
    )

    let snapshot = statusService.evaluate(configuration: configuration)

    #expect(snapshot.advertisement?.serviceName == "Brother HL-2170W series via PrinterBridge")
}

@Test
func bridgeStatusProxyModeDoesNotRequireSharedQueue() {
    let runner = InventoryStubCommandRunner { executable, arguments in
        let command = ([executable] + arguments).joined(separator: " ")

        switch command {
        case "/usr/bin/lpstat -p":
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: "printer Brother_HL_2170W_series is idle.  enabled since Wed Aug 13 12:11:45 2025",
                standardError: ""
            )
        case "/usr/bin/lpstat -v":
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: "device for Brother_HL_2170W_series: usb://Brother/HL-2170W",
                standardError: ""
            )
        case "/usr/bin/lpstat -l -p Brother_HL_2170W_series":
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: """
                printer Brother_HL_2170W_series is idle.  enabled since Wed Aug 13 12:11:45 2025
                \tDescription: Brother HL-2170W series
                \tConnection: direct
                """,
                standardError: ""
            )
        case "/usr/bin/lpoptions -p Brother_HL_2170W_series -l":
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: """
                PageSize/Media Size: *Letter Legal A4
                Resolution/Resolution: *600dpi 1200dpi
                """,
                standardError: ""
            )
        case "/usr/bin/ipptool -tv ipp://localhost:631/printers/Brother_HL_2170W_series /usr/share/cups/ipptool/get-printer-attributes.test":
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: """
                "/usr/share/cups/ipptool/get-printer-attributes.test":
                    Get-Printer-Attributes:
                        attributes-charset (charset) = utf-8
                    Get printer attributes using get-printer-attributes                  [PASS]
                        printer-is-shared (boolean) = false
                        printer-info (textWithoutLanguage) = Brother HL-2170W series
                        printer-make-and-model (textWithoutLanguage) = Brother HL-2170W series CUPS
                        document-format-supported (1setOf mimeMediaType) = application/pdf,image/pwg-raster,image/urf
                        printer-resolution-supported (1setOf resolution) = 600dpi
                """,
                standardError: ""
            )
        default:
            return CommandResult(executable: executable, arguments: arguments, exitCode: 1, standardOutput: "", standardError: "unexpected command")
        }
    }

    let inventoryService = PrinterInventoryService(runner: runner)
    let attributeService = IPPPrinterAttributeService(runner: runner)
    let statusService = BridgeStatusService(
        inventoryService: inventoryService,
        attributeService: attributeService,
        hostNameProvider: { "test-host.local" }
    )
    let configuration = BridgeConfiguration(
        isEnabled: true,
        selectedQueueName: "Brother_HL_2170W_series",
        advertisedNameOverride: nil,
        exposureMode: .proxy
    )

    let snapshot = statusService.evaluate(configuration: configuration)

    #expect(snapshot.activationState == .ready)
    #expect(snapshot.isPublishable == true)
    #expect(snapshot.advertisement?.printerURI == "ipp://test-host.local:8631/printers/Brother_HL_2170W_series")
    #expect(snapshot.advertisement?.warnings.contains(where: { $0.contains("not shared yet") }) == false)
}
