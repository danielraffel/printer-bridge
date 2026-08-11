import Foundation
import Testing
@testable import PrinterBridgeCore

@Test
func processCommandRunnerCapturesOutputLargerThanAPipeBuffer() {
    let runner = ProcessCommandRunner(timeout: 5)
    let result = runner.run(
        executable: "/usr/bin/awk",
        arguments: ["BEGIN { for (i = 0; i < 20000; i++) printf \"abcdefghij\" }"]
    )

    #expect(result.exitCode == 0)
    #expect(result.standardOutput.utf8.count == 200_000)
    #expect(result.standardError.isEmpty)
}

@Test
func processCommandRunnerTerminatesCommandsThatExceedTheTimeout() {
    let runner = ProcessCommandRunner(timeout: 0.1)
    let result = runner.run(executable: "/bin/sleep", arguments: ["5"])

    #expect(result.exitCode == 124)
    #expect(result.standardError.contains("timed out"))
}
