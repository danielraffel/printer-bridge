import Testing
@testable import PrinterBridgeCore

@Test
func printJobSnapshotParsesActiveAndCompletedJobs() {
    let runner = InventoryStubCommandRunner { executable, arguments in
        let command = ([executable] + arguments).joined(separator: " ")

        switch command {
        case "/usr/bin/lpstat -W not-completed -o":
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: """
                Brother_HL_2170W_series-501 mobile 4096 Tue Mar 10 17:59:01 2026
                Other_Printer-12 mobile 1024 Tue Mar 10 16:10:00 2026
                """,
                standardError: ""
            )
        case "/usr/bin/lpstat -W completed -o":
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 0,
                standardOutput: """
                Brother_HL_2170W_series-500 mobile 2048 Tue Mar 10 17:52:00 2026
                Brother_HL_2170W_series-499 mobile 1024 Tue Mar 10 17:40:00 2026
                """,
                standardError: ""
            )
        default:
            return CommandResult(executable: executable, arguments: arguments, exitCode: 1, standardOutput: "", standardError: "unexpected command")
        }
    }

    let service = PrintJobQueueService(runner: runner)
    let snapshot = service.snapshot(forQueueNamed: "Brother_HL_2170W_series")

    #expect(snapshot.activeJobs.count == 1)
    #expect(snapshot.activeJobs.first?.id == "Brother_HL_2170W_series-501")
    #expect(snapshot.completedJobs.count == 2)
    #expect(snapshot.completedJobs.first?.id == "Brother_HL_2170W_series-500")
}
