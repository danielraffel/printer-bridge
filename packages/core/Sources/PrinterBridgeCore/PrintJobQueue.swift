import Foundation

public struct PrintJob: Equatable, Identifiable, Sendable {
    public enum State: String, Equatable, Sendable {
        case active
        case completed
    }

    public let id: String
    public let queueName: String
    public let jobNumber: Int?
    public let owner: String
    public let sizeBytes: Int?
    public let submittedAt: String
    public let state: State
    public let rawLine: String

    public init(
        id: String,
        queueName: String,
        jobNumber: Int?,
        owner: String,
        sizeBytes: Int?,
        submittedAt: String,
        state: State,
        rawLine: String
    ) {
        self.id = id
        self.queueName = queueName
        self.jobNumber = jobNumber
        self.owner = owner
        self.sizeBytes = sizeBytes
        self.submittedAt = submittedAt
        self.state = state
        self.rawLine = rawLine
    }
}

public struct PrintJobQueueSnapshot: Equatable, Sendable {
    public let queueName: String?
    public let activeJobs: [PrintJob]
    public let completedJobs: [PrintJob]

    public init(queueName: String?, activeJobs: [PrintJob], completedJobs: [PrintJob]) {
        self.queueName = queueName
        self.activeJobs = activeJobs
        self.completedJobs = completedJobs
    }
}

public struct PrintJobQueueService {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func snapshot(forQueueNamed queueName: String?) -> PrintJobQueueSnapshot {
        let activeResult = runner.run(executable: SystemTool.lpstat.path, arguments: ["-W", "not-completed", "-o"])
        let completedResult = runner.run(executable: SystemTool.lpstat.path, arguments: ["-W", "completed", "-o"])

        return PrintJobQueueSnapshot(
            queueName: queueName,
            activeJobs: parseJobs(from: activeResult.combinedOutput, state: .active, filterQueueName: queueName),
            completedJobs: parseJobs(from: completedResult.combinedOutput, state: .completed, filterQueueName: queueName)
        )
    }

    @discardableResult
    public func cancelAllActiveJobs(forQueueNamed queueName: String?) -> Bool {
        guard let queueName, !queueName.isEmpty else {
            return false
        }

        let result = runner.run(executable: SystemTool.cancel.path, arguments: ["-a", queueName])
        return result.exitCode == 0
    }

    private func parseJobs(
        from output: String,
        state: PrintJob.State,
        filterQueueName: String?
    ) -> [PrintJob] {
        output
            .split(separator: "\n")
            .compactMap { parseJobLine(String($0), state: state) }
            .filter { job in
                guard let filterQueueName, !filterQueueName.isEmpty else {
                    return true
                }

                return job.queueName == filterQueueName
            }
            .sorted { lhs, rhs in
                if lhs.state != rhs.state {
                    return lhs.state == .active
                }
                return lhs.id > rhs.id
            }
    }

    private func parseJobLine(_ line: String, state: PrintJob.State) -> PrintJob? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let tokens = trimmed.split(whereSeparator: \.isWhitespace)
        guard tokens.count >= 4 else {
            return nil
        }

        let jobIdentifier = String(tokens[0])
        let owner = String(tokens[1])
        let sizeBytes = Int(tokens[2])
        let submittedAt = tokens.dropFirst(3).joined(separator: " ")

        guard let separatorIndex = jobIdentifier.lastIndex(of: "-") else {
            return nil
        }

        let queueName = String(jobIdentifier[..<separatorIndex])
        let jobNumber = Int(jobIdentifier[jobIdentifier.index(after: separatorIndex)...])

        return PrintJob(
            id: jobIdentifier,
            queueName: queueName,
            jobNumber: jobNumber,
            owner: owner,
            sizeBytes: sizeBytes,
            submittedAt: submittedAt,
            state: state,
            rawLine: trimmed
        )
    }
}
