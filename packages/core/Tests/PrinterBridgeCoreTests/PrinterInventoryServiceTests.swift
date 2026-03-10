import Testing
@testable import PrinterBridgeCore

struct InventoryStubCommandRunner: CommandRunning {
    let handler: (String, [String]) -> CommandResult

    func run(executable: String, arguments: [String]) -> CommandResult {
        handler(executable, arguments)
    }
}

@Test
func listQueuesMergesStateAndDeviceURI() {
    let runner = InventoryStubCommandRunner { executable, arguments in
        let command = ([executable] + arguments).joined(separator: " ")

        switch command {
        case "/usr/bin/lpstat -p":
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: """
                printer Brother_HL_2170W_series is idle.  enabled since Wed Aug 13 12:11:45 2025
                printer Office_Laser is idle.  enabled since Mon Mar 10 09:01:00 2026
                """,
                standardError: ""
            )
        case "/usr/bin/lpstat -v":
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: """
                device for Brother_HL_2170W_series: dnssd://Brother.local./?bidi
                device for Office_Laser: usb://Example/OfficeLaser
                """,
                standardError: ""
            )
        default:
            return CommandResult(executable: executable, arguments: arguments, exitCode: 1, standardOutput: "", standardError: "unexpected command")
        }
    }

    let queues = PrinterInventoryService(runner: runner).listQueues()

    #expect(queues.count == 2)
    #expect(queues.first?.name == "Brother_HL_2170W_series")
    #expect(queues.first?.status == "idle")
    #expect(queues.first?.stateDetail == "enabled since Wed Aug 13 12:11:45 2025")
    #expect(queues.first?.deviceURI == "dnssd://Brother.local./?bidi")
}

@Test
func inspectQueueParsesDetailAndOptions() {
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
                \tInterface: /private/etc/cups/ppd/Brother_HL_2170W_series.ppd
                \tUsers allowed:
                \t\t(all)
                \tForms allowed:
                \t\t(none)
                \tBanner required
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
                Duplex/2-Sided Printing: *None DuplexNoTumble DuplexTumble
                """,
                standardError: ""
            )
        default:
            return CommandResult(executable: executable, arguments: arguments, exitCode: 1, standardOutput: "", standardError: "unexpected command")
        }
    }

    let inspection = PrinterInventoryService(runner: runner).inspectQueue(named: "Brother_HL_2170W_series")

    #expect(inspection != nil)
    #expect(inspection?.detail.description == "Brother HL-2170W series")
    #expect(inspection?.detail.connection == "direct")
    #expect(inspection?.detail.usersAllowed == ["(all)"])
    #expect(inspection?.detail.flags.contains("Banner required") == true)
    #expect(inspection?.options.count == 2)
    #expect(inspection?.options.first?.defaultValue == "Letter")
    #expect(inspection?.suitability == .ready)
}
