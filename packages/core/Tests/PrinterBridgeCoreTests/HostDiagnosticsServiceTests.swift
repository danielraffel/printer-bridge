import Testing
@testable import PrinterBridgeCore

private struct StubCommandRunner: CommandRunning {
    let handler: (String, [String]) -> CommandResult

    func run(executable: String, arguments: [String]) -> CommandResult {
        handler(executable, arguments)
    }
}

@Test
func printerInspectionTargetsRequestedQueue() {
    let runner = StubCommandRunner { executable, arguments in
        let command = ([executable] + arguments).joined(separator: " ")

        if command.contains("/usr/bin/lpstat -l -p Brother_HL_2170W_series") {
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: "printer Brother_HL_2170W_series is idle.",
                standardError: ""
            )
        }

        if command.contains("/usr/bin/lpoptions -p Brother_HL_2170W_series -l") {
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: "Resolution/Resolution: *300dpi 600dpi",
                standardError: ""
            )
        }

        return CommandResult(
            executable: executable,
            arguments: arguments,
            exitCode: 1,
            standardOutput: "",
            standardError: "unexpected command"
        )
    }

    let report = HostDiagnosticsService(runner: runner).inspectPrinterReport(named: "Brother_HL_2170W_series")

    #expect(report.success)
    #expect(report.renderedText.contains("Brother_HL_2170W_series"))
    #expect(report.renderedText.contains("Resolution/Resolution"))
}

@Test
func doctorSummarizesLegacyBridgeDiscovery() {
    let runner = StubCommandRunner { executable, arguments in
        let command = ([executable] + arguments).joined(separator: " ")

        switch command {
        case "/usr/bin/sw_vers":
            return CommandResult(executable: executable, arguments: arguments, exitCode: 0, standardOutput: "ProductVersion:\t26.3", standardError: "")
        case "/usr/bin/uname -m":
            return CommandResult(executable: executable, arguments: arguments, exitCode: 0, standardOutput: "arm64", standardError: "")
        case "/usr/bin/lpstat -d":
            return CommandResult(executable: executable, arguments: arguments, exitCode: 0, standardOutput: "system default destination: Brother_HL_2170W_series", standardError: "")
        case "/usr/bin/lpstat -p":
            return CommandResult(executable: executable, arguments: arguments, exitCode: 0, standardOutput: "printer Brother_HL_2170W_series is idle.", standardError: "")
        case "/usr/bin/lpstat -v":
            return CommandResult(executable: executable, arguments: arguments, exitCode: 0, standardOutput: "device for Brother_HL_2170W_series: dnssd://Brother.local./?bidi", standardError: "")
        case "/usr/bin/ippfind -T 2 _ipp._tcp,_universal --print":
            return CommandResult(executable: executable, arguments: arguments, exitCode: 0, standardOutput: "ipp://Daniels-Mac-mini-5.local:10631/p/2DF440", standardError: "")
        case "/usr/bin/ippfind -T 2 _ipp._tcp --print":
            return CommandResult(executable: executable, arguments: arguments, exitCode: 0, standardOutput: "ipp://BRN001BA91508A0.local:631/duerqxesz5090", standardError: "")
        case "/usr/bin/lpstat -l -p Brother_HL_2170W_series":
            return CommandResult(executable: executable, arguments: arguments, exitCode: 0, standardOutput: "Connection: direct", standardError: "")
        case "/usr/bin/lpoptions -p Brother_HL_2170W_series -l":
            return CommandResult(executable: executable, arguments: arguments, exitCode: 0, standardOutput: "Duplex/2-Sided Printing: *None DuplexNoTumble DuplexTumble", standardError: "")
        default:
            return CommandResult(executable: executable, arguments: arguments, exitCode: 1, standardOutput: "", standardError: "unexpected command")
        }
    }

    let report = HostDiagnosticsService(runner: runner).doctor(printerName: "Brother_HL_2170W_series")

    #expect(report.success)
    #expect(report.summary.contains("default printer: Brother_HL_2170W_series"))
    #expect(report.summary.contains("legacy bridge endpoint detected on port 10631"))
}
