import Foundation

public struct CommandResult: Equatable {
    public let executable: String
    public let arguments: [String]
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(
        executable: String,
        arguments: [String],
        exitCode: Int32,
        standardOutput: String,
        standardError: String
    ) {
        self.executable = executable
        self.arguments = arguments
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var combinedOutput: String {
        let stdout = standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = standardError.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (stdout.isEmpty, stderr.isEmpty) {
        case (false, true):
            return stdout
        case (true, false):
            return stderr
        case (false, false):
            return "\(stdout)\n\(stderr)"
        case (true, true):
            return ""
        }
    }

    public var commandDescription: String {
        ([executable] + arguments).joined(separator: " ")
    }
}

public protocol CommandRunning {
    func run(executable: String, arguments: [String]) -> CommandResult
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(executable: String, arguments: [String]) -> CommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 127,
                standardOutput: "",
                standardError: error.localizedDescription
            )
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        return CommandResult(
            executable: executable,
            arguments: arguments,
            exitCode: process.terminationStatus,
            standardOutput: stdout,
            standardError: stderr
        )
    }
}

public enum SystemTool: CaseIterable {
    case swVers
    case uname
    case lpstat
    case lp
    case lpoptions
    case ipptool
    case ippfind
    case dnsSD
    case cancel
    case launchctl

    public var path: String {
        switch self {
        case .swVers:
            return "/usr/bin/sw_vers"
        case .uname:
            return "/usr/bin/uname"
        case .lpstat:
            return "/usr/bin/lpstat"
        case .lp:
            return "/usr/bin/lp"
        case .lpoptions:
            return "/usr/bin/lpoptions"
        case .ipptool:
            return "/usr/bin/ipptool"
        case .ippfind:
            return "/usr/bin/ippfind"
        case .dnsSD:
            return "/usr/bin/dns-sd"
        case .cancel:
            return "/usr/bin/cancel"
        case .launchctl:
            return "/bin/launchctl"
        }
    }

    public var isRequired: Bool {
        switch self {
        case .swVers, .uname, .lpstat, .lp, .lpoptions, .ipptool, .ippfind:
            return true
        case .dnsSD, .cancel, .launchctl:
            return false
        }
    }
}
