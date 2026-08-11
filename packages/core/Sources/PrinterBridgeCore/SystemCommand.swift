import Foundation
import Darwin

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
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 15) {
        self.timeout = timeout
    }

    public func run(executable: String, arguments: [String]) -> CommandResult {
        let fileManager = FileManager.default
        let outputDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("PrinterBridgeCommand-\(UUID().uuidString)", isDirectory: true)
        let stdoutURL = outputDirectory.appendingPathComponent("stdout")
        let stderrURL = outputDirectory.appendingPathComponent("stderr")

        do {
            try fileManager.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard fileManager.createFile(atPath: stdoutURL.path, contents: nil),
                  fileManager.createFile(atPath: stderrURL.path, contents: nil)
            else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 127,
                standardOutput: "",
                standardError: error.localizedDescription
            )
        }
        defer {
            try? fileManager.removeItem(at: outputDirectory)
        }

        let stdoutHandle: FileHandle
        let stderrHandle: FileHandle

        do {
            stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            stderrHandle = try FileHandle(forWritingTo: stderrURL)
        } catch {
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 127,
                standardOutput: "",
                standardError: error.localizedDescription
            )
        }

        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
        }

        posix_spawn_file_actions_adddup2(&fileActions, stdoutHandle.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrHandle.fileDescriptor, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, stdoutHandle.fileDescriptor)
        posix_spawn_file_actions_addclose(&fileActions, stderrHandle.fileDescriptor)

        var pid: pid_t = 0
        var commandArguments = [executable]
        commandArguments.append(contentsOf: arguments)
        var argumentPointers: [UnsafeMutablePointer<CChar>?] = commandArguments.map { strdup($0) }
        argumentPointers.append(nil)
        defer {
            for pointer in argumentPointers where pointer != nil {
                free(pointer)
            }
        }

        let spawnResult = executable.withCString { executablePointer in
            argumentPointers.withUnsafeMutableBufferPointer { argumentBuffer in
                posix_spawn(
                    &pid,
                    executablePointer,
                    &fileActions,
                    nil,
                    argumentBuffer.baseAddress,
                    environ
                )
            }
        }

        try? stdoutHandle.close()
        try? stderrHandle.close()

        guard spawnResult == 0 else {
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: 127,
                standardOutput: "",
                standardError: String(cString: strerror(spawnResult))
            )
        }

        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        var timedOut = false

        while waitpid(pid, &status, WNOHANG) == 0 {
            if Date() >= deadline {
                timedOut = true
                kill(pid, SIGTERM)

                let terminationDeadline = Date().addingTimeInterval(1)
                while waitpid(pid, &status, WNOHANG) == 0, Date() < terminationDeadline {
                    usleep(10_000)
                }

                if waitpid(pid, &status, WNOHANG) == 0 {
                    kill(pid, SIGKILL)
                    waitpid(pid, &status, 0)
                }
                break
            }
            usleep(10_000)
        }

        let stdoutData = (try? Data(contentsOf: stdoutURL)) ?? Data()
        let stderrData = (try? Data(contentsOf: stderrURL)) ?? Data()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        var stderr = String(data: stderrData, encoding: .utf8) ?? ""
        if timedOut {
            let timeoutMessage = "Command timed out after \(timeout) seconds."
            stderr = stderr.isEmpty ? timeoutMessage : "\(stderr)\n\(timeoutMessage)"
        }

        return CommandResult(
            executable: executable,
            arguments: arguments,
            exitCode: timedOut ? 124 : exitCode(fromWaitStatus: status),
            standardOutput: stdout,
            standardError: stderr
        )
    }

    private func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let terminatingSignal = status & 0x7f
        if terminatingSignal == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + terminatingSignal
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
