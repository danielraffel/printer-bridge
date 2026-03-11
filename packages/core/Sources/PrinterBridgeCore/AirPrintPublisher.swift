import Foundation

public enum BonjourAdvertisementError: LocalizedError, Equatable {
    case missingAdvertisementPlan
    case failedToStart(command: String, reason: String)
    case startupTimedOut(command: String, output: String)
    case processExited(command: String, exitCode: Int32, output: String)

    public var errorDescription: String? {
        switch self {
        case .missingAdvertisementPlan:
            return "The bridge did not generate an AirPrint advertisement plan."
        case let .failedToStart(command, reason):
            return "Failed to start Bonjour publication with `\(command)`: \(reason)"
        case let .startupTimedOut(command, output):
            if output.isEmpty {
                return "Bonjour publication did not become active before the timeout for `\(command)`."
            }
            return "Bonjour publication did not become active before the timeout for `\(command)`. Output: \(output)"
        case let .processExited(command, exitCode, output):
            if output.isEmpty {
                return "Bonjour publication exited early with code \(exitCode) for `\(command)`."
            }
            return "Bonjour publication exited early with code \(exitCode) for `\(command)`. Output: \(output)"
        }
    }
}

public struct BonjourRegistrationCommand: Equatable, Sendable {
    public static let serviceType = "_ipp._tcp,_universal"

    public let executable: String
    public let arguments: [String]

    public init(
        advertisementPlan: AirPrintAdvertisementPlan,
        executable: String = SystemTool.dnsSD.path,
        domain: String = "."
    ) {
        self.executable = executable
        self.arguments = [
            "-R",
            advertisementPlan.serviceName,
            Self.serviceType,
            domain,
            String(advertisementPlan.port),
        ] + advertisementPlan.txtRecords.map { "\($0.key)=\($0.value)" }
    }

    public var commandDescription: String {
        ([executable] + arguments).joined(separator: " ")
    }
}

public final class BonjourAdvertisementSession {
    public let advertisementPlan: AirPrintAdvertisementPlan
    public let command: BonjourRegistrationCommand

    private let process: Process
    private let state: SessionState
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe

    fileprivate init(
        advertisementPlan: AirPrintAdvertisementPlan,
        command: BonjourRegistrationCommand,
        process: Process,
        state: SessionState,
        stdoutPipe: Pipe,
        stderrPipe: Pipe
    ) {
        self.advertisementPlan = advertisementPlan
        self.command = command
        self.process = process
        self.state = state
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
    }

    deinit {
        stop()
    }

    public var isRunning: Bool {
        process.isRunning
    }

    public var output: String {
        state.output
    }

    @discardableResult
    public func stop(gracePeriod: TimeInterval = 1.5) -> Int32 {
        guard process.isRunning else {
            return process.terminationStatus
        }

        process.terminate()
        let deadline = Date().addingTimeInterval(gracePeriod)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        if process.isRunning {
            process.interrupt()
        }

        while process.isRunning {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        return process.terminationStatus
    }

    public func waitUntilExit() -> Int32 {
        process.waitUntilExit()
        return process.terminationStatus
    }
}

public struct BonjourAdvertisementService {
    public init() {}

    public func publish(
        _ advertisementPlan: AirPrintAdvertisementPlan,
        startupTimeout: TimeInterval = 5,
        outputHandler: (@Sendable (String) -> Void)? = nil
    ) throws -> BonjourAdvertisementSession {
        let command = BonjourRegistrationCommand(advertisementPlan: advertisementPlan)
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let state = SessionState()

        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { terminatedProcess in
            state.markTerminated(status: terminatedProcess.terminationStatus)
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = makeReadabilityHandler(
            state: state,
            outputHandler: outputHandler
        )
        stderrPipe.fileHandleForReading.readabilityHandler = makeReadabilityHandler(
            state: state,
            outputHandler: outputHandler
        )

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw BonjourAdvertisementError.failedToStart(
                command: command.commandDescription,
                reason: error.localizedDescription
            )
        }

        switch state.waitForStartup(timeout: startupTimeout) {
        case .active:
            return BonjourAdvertisementSession(
                advertisementPlan: advertisementPlan,
                command: command,
                process: process,
                state: state,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe
            )
        case let .terminated(exitCode):
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw BonjourAdvertisementError.processExited(
                command: command.commandDescription,
                exitCode: exitCode,
                output: state.output
            )
        case .timedOut:
            let session = BonjourAdvertisementSession(
                advertisementPlan: advertisementPlan,
                command: command,
                process: process,
                state: state,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe
            )
            session.stop()
            throw BonjourAdvertisementError.startupTimedOut(
                command: command.commandDescription,
                output: state.output
            )
        }
    }

    private func makeReadabilityHandler(
        state: SessionState,
        outputHandler: (@Sendable (String) -> Void)?
    ) -> @Sendable (FileHandle) -> Void {
        { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }

            guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else {
                return
            }

            state.append(chunk)
            outputHandler?(chunk)
        }
    }
}

private final class SessionState: @unchecked Sendable {
    enum StartupResult {
        case active
        case terminated(Int32)
        case timedOut
    }

    private let lock = NSLock()
    private let startupSemaphore = DispatchSemaphore(value: 0)
    private var logChunks: [String] = []
    private var isActive = false
    private var terminationStatus: Int32?

    var output: String {
        lock.withLock {
            logChunks.joined(separator: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func append(_ chunk: String) {
        lock.withLock {
            logChunks.append(chunk)
            if !isActive, chunk.contains("Name now registered and active") {
                isActive = true
                startupSemaphore.signal()
            }
        }
    }

    func markTerminated(status: Int32) {
        lock.withLock {
            terminationStatus = status
            if !isActive {
                startupSemaphore.signal()
            }
        }
    }

    func waitForStartup(timeout: TimeInterval) -> StartupResult {
        let dispatchTimeout = DispatchTime.now() + timeout
        if startupSemaphore.wait(timeout: dispatchTimeout) == .timedOut {
            return .timedOut
        }

        return lock.withLock {
            if isActive {
                return .active
            }

            return .terminated(terminationStatus ?? 1)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
