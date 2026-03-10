import Testing
@testable import PrinterBridgeCore

@Test
func ippAttributeServiceParsesPrinterAttributes() {
    let runner = InventoryStubCommandRunner { executable, arguments in
        let command = ([executable] + arguments).joined(separator: " ")

        switch command {
        case "/usr/bin/ipptool -tv ipp://localhost:631/printers/Brother_HL_2170W_series /usr/share/cups/ipptool/get-printer-attributes.test":
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: """
                "/usr/share/cups/ipptool/get-printer-attributes.test":
                    Get-Printer-Attributes:
                        attributes-charset (charset) = utf-8
                        attributes-natural-language (naturalLanguage) = en
                        printer-uri (uri) = ipp://localhost:631/printers/Brother_HL_2170W_series
                    Get printer attributes using get-printer-attributes                  [PASS]
                        status-code = successful-ok (successful-ok)
                        printer-is-shared (boolean) = false
                        printer-info (textWithoutLanguage) = Brother HL-2170W series
                        color-supported (boolean) = false
                        document-format-supported (1setOf mimeMediaType) = application/pdf,image/pwg-raster,image/urf
                        printer-resolution-supported (1setOf resolution) = 300dpi,600dpi,1200dpi
                """,
                standardError: ""
            )
        default:
            return CommandResult(executable: executable, arguments: arguments, exitCode: 1, standardOutput: "", standardError: "unexpected command")
        }
    }

    let service = IPPPrinterAttributeService(runner: runner)
    let snapshot = service.fetchAttributes(forQueueNamed: "Brother_HL_2170W_series")

    #expect(snapshot?.queueName == "Brother_HL_2170W_series")
    #expect(snapshot?.printerURI == "ipp://localhost:631/printers/Brother_HL_2170W_series")
    #expect(snapshot?.boolValue(named: "printer-is-shared") == false)
    #expect(snapshot?.stringValue(named: "printer-info") == "Brother HL-2170W series")
    #expect(snapshot?.values(named: "document-format-supported") == ["application/pdf", "image/pwg-raster", "image/urf"])
    #expect(snapshot?.values(named: "printer-resolution-supported") == ["300dpi", "600dpi", "1200dpi"])
}
