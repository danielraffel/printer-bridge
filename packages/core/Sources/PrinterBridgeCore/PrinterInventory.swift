import Foundation

public enum PrinterBridgeSuitability: String, Equatable, Sendable {
    case ready = "ready"
    case likelyReady = "likely-ready"
    case needsReview = "needs-review"
}

public struct PrinterQueueSummary: Equatable, Identifiable, Sendable {
    public let name: String
    public let status: String
    public let stateDetail: String?
    public let deviceURI: String?

    public var id: String { name }

    public init(name: String, status: String, stateDetail: String?, deviceURI: String?) {
        self.name = name
        self.status = status
        self.stateDetail = stateDetail
        self.deviceURI = deviceURI
    }
}

public struct PrinterOptionChoice: Equatable, Sendable {
    public let value: String
    public let isDefault: Bool

    public init(value: String, isDefault: Bool) {
        self.value = value
        self.isDefault = isDefault
    }
}

public struct PrinterOption: Equatable, Sendable {
    public let key: String
    public let displayName: String
    public let values: [PrinterOptionChoice]

    public init(key: String, displayName: String, values: [PrinterOptionChoice]) {
        self.key = key
        self.displayName = displayName
        self.values = values
    }

    public var defaultValue: String? {
        values.first(where: \.isDefault)?.value
    }
}

public struct PrinterQueueDetail: Equatable, Sendable {
    public let rawStatusLine: String
    public let attributes: [String: String]
    public let listAttributes: [String: [String]]
    public let flags: [String]

    public init(
        rawStatusLine: String,
        attributes: [String: String],
        listAttributes: [String: [String]],
        flags: [String]
    ) {
        self.rawStatusLine = rawStatusLine
        self.attributes = attributes
        self.listAttributes = listAttributes
        self.flags = flags
    }

    public var description: String? { attribute(named: "Description") }
    public var connection: String? { attribute(named: "Connection") }
    public var interfacePath: String? { attribute(named: "Interface") }
    public var contentTypes: String? { attribute(named: "Content types") }
    public var printerTypes: String? { attribute(named: "Printer types") }
    public var usersAllowed: [String] { listAttribute(named: "Users allowed") }
    public var formsAllowed: [String] { listAttribute(named: "Forms allowed") }

    public func attribute(named key: String) -> String? {
        let value = attributes[key]
        return value?.isEmpty == true ? nil : value
    }

    public func listAttribute(named key: String) -> [String] {
        listAttributes[key] ?? []
    }
}

public struct PrinterQueueInspection: Equatable, Sendable {
    public let summary: PrinterQueueSummary
    public let detail: PrinterQueueDetail
    public let options: [PrinterOption]

    public init(summary: PrinterQueueSummary, detail: PrinterQueueDetail, options: [PrinterOption]) {
        self.summary = summary
        self.detail = detail
        self.options = options
    }

    public var suitability: PrinterBridgeSuitability {
        if summary.deviceURI == nil || summary.deviceURI?.isEmpty == true {
            return .needsReview
        }

        let optionKeys = Set(options.map(\.key))
        if optionKeys.contains("PageSize") || optionKeys.contains("Resolution") {
            return .ready
        }

        if !options.isEmpty || detail.connection != nil {
            return .likelyReady
        }

        return .needsReview
    }

    public var suitabilityReason: String {
        switch suitability {
        case .ready:
            return "queue exposes a device URI and printable option set"
        case .likelyReady:
            return "queue is installed, but capability data is incomplete"
        case .needsReview:
            return "queue is missing the data needed for reliable AirPrint bridging"
        }
    }
}

public struct PrinterInventorySnapshot: Equatable, Sendable {
    public let queues: [PrinterQueueSummary]
    public let preferredQueueName: String?
    public let preferredInspection: PrinterQueueInspection?

    public init(
        queues: [PrinterQueueSummary],
        preferredQueueName: String?,
        preferredInspection: PrinterQueueInspection?
    ) {
        self.queues = queues
        self.preferredQueueName = preferredQueueName
        self.preferredInspection = preferredInspection
    }
}

public struct PrinterInventoryService {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func listQueues() -> [PrinterQueueSummary] {
        let stateResult = runner.run(executable: SystemTool.lpstat.path, arguments: ["-p"])
        let uriResult = runner.run(executable: SystemTool.lpstat.path, arguments: ["-v"])

        let stateByName = Dictionary(uniqueKeysWithValues: parseQueueStates(from: stateResult.combinedOutput).map { ($0.name, $0) })
        let uriByName = parseQueueURIs(from: uriResult.combinedOutput)

        let names = Set(stateByName.keys).union(uriByName.keys).sorted()
        return names.map { name in
            let state = stateByName[name]
            return PrinterQueueSummary(
                name: name,
                status: state?.status ?? "unknown",
                stateDetail: state?.stateDetail,
                deviceURI: uriByName[name]
            )
        }
    }

    public func inspectQueue(named name: String) -> PrinterQueueInspection? {
        let summary = listQueues().first(where: { $0.name == name })

        let detailResult = runner.run(executable: SystemTool.lpstat.path, arguments: ["-l", "-p", name])
        let optionResult = runner.run(executable: SystemTool.lpoptions.path, arguments: ["-p", name, "-l"])

        guard detailResult.exitCode == 0 || summary != nil else {
            return nil
        }

        let detail = parseDetail(from: detailResult.combinedOutput)
        let options = parseOptions(from: optionResult.combinedOutput)

        let resolvedSummary: PrinterQueueSummary
        if let summary {
            resolvedSummary = summary
        } else {
            let parsed = parseStateLine(detail.rawStatusLine)
            resolvedSummary = PrinterQueueSummary(
                name: parsed?.name ?? name,
                status: parsed?.status ?? "unknown",
                stateDetail: parsed?.stateDetail,
                deviceURI: nil
            )
        }

        return PrinterQueueInspection(summary: resolvedSummary, detail: detail, options: options)
    }

    public func snapshot(preferredQueueName: String? = ProjectMetadata.primaryTargetPrinter) -> PrinterInventorySnapshot {
        let queues = listQueues()
        let preferredQueueName = preferredQueueName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredInspection = preferredQueueName.flatMap { inspectQueue(named: $0) }

        return PrinterInventorySnapshot(
            queues: queues,
            preferredQueueName: preferredQueueName,
            preferredInspection: preferredInspection
        )
    }

    public func renderQueueList() -> String {
        let queues = listQueues()
        var lines = [
            "PrinterBridge queue discovery",
            "",
            "Summary",
            "- configured queues: \(queues.count)",
            "",
        ]

        for (index, queue) in queues.enumerated() {
            lines.append("[\(queue.name)]")
            lines.append("status: \(queue.status)")
            if let stateDetail = queue.stateDetail, !stateDetail.isEmpty {
                lines.append("state detail: \(stateDetail)")
            }
            if let deviceURI = queue.deviceURI, !deviceURI.isEmpty {
                lines.append("device URI: \(deviceURI)")
            }

            if index < queues.count - 1 {
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    public func renderInspection(named name: String) -> String {
        guard let inspection = inspectQueue(named: name) else {
            return """
            PrinterBridge printer inspection

            Summary
            - target printer: \(name)
            - result: queue not found
            """
        }

        var lines = [
            "PrinterBridge printer inspection",
            "",
            "Summary",
            "- target printer: \(inspection.summary.name)",
            "- suitability: \(inspection.suitability.rawValue)",
            "- reason: \(inspection.suitabilityReason)",
            "- option count: \(inspection.options.count)",
            "",
            "Core Details",
            "status: \(inspection.summary.status)",
        ]

        if let stateDetail = inspection.summary.stateDetail, !stateDetail.isEmpty {
            lines.append("state detail: \(stateDetail)")
        }
        if let deviceURI = inspection.summary.deviceURI, !deviceURI.isEmpty {
            lines.append("device URI: \(deviceURI)")
        }
        if let description = inspection.detail.description {
            lines.append("description: \(description)")
        }
        if let connection = inspection.detail.connection {
            lines.append("connection: \(connection)")
        }
        if let interfacePath = inspection.detail.interfacePath {
            lines.append("interface: \(interfacePath)")
        }

        if !inspection.detail.flags.isEmpty {
            lines.append("")
            lines.append("Flags")
            lines.append(contentsOf: inspection.detail.flags.map { "- \($0)" })
        }

        if !inspection.detail.listAttributes.isEmpty {
            lines.append("")
            lines.append("Lists")
            for key in inspection.detail.listAttributes.keys.sorted() {
                let values = inspection.detail.listAttributes[key] ?? []
                let renderedValues = values.isEmpty ? "(empty)" : values.joined(separator: ", ")
                lines.append("- \(key): \(renderedValues)")
            }
        }

        if !inspection.options.isEmpty {
            lines.append("")
            lines.append("Options")
            for option in inspection.options {
                let values = option.values.map { choice in
                    choice.isDefault ? "*\(choice.value)" : choice.value
                }.joined(separator: " ")
                lines.append("- \(option.key) (\(option.displayName)): \(values)")
            }
        }

        return lines.joined(separator: "\n")
    }

    public func renderSnapshot(preferredQueueName: String? = ProjectMetadata.primaryTargetPrinter) -> String {
        let snapshot = snapshot(preferredQueueName: preferredQueueName)
        var lines = [
            "PrinterBridge daemon inventory snapshot",
            "",
            "Summary",
            "- queues: \(snapshot.queues.count)",
        ]

        if let preferredQueueName = snapshot.preferredQueueName, !preferredQueueName.isEmpty {
            lines.append("- preferred queue: \(preferredQueueName)")
        }
        if let preferredInspection = snapshot.preferredInspection {
            lines.append("- preferred suitability: \(preferredInspection.suitability.rawValue)")
        }

        lines.append("")
        lines.append(renderQueueList())

        if let preferredQueueName = snapshot.preferredQueueName, !preferredQueueName.isEmpty {
            lines.append("")
            lines.append(renderInspection(named: preferredQueueName))
        }

        return lines.joined(separator: "\n")
    }

    private func parseQueueStates(from output: String) -> [PrinterQueueSummary] {
        output
            .split(separator: "\n")
            .compactMap { parseStateLine(String($0)) }
            .map {
                PrinterQueueSummary(
                    name: $0.name,
                    status: $0.status,
                    stateDetail: $0.stateDetail,
                    deviceURI: nil
                )
            }
    }

    private func parseQueueURIs(from output: String) -> [String: String] {
        var urisByName: [String: String] = [:]

        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            guard line.hasPrefix("device for ") else { continue }
            guard let separator = line.firstIndex(of: ":") else { continue }

            let nameStart = line.index(line.startIndex, offsetBy: "device for ".count)
            let name = String(line[nameStart..<separator])
            let valueStart = line.index(after: separator)
            let uri = line[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
            urisByName[name] = uri.isEmpty ? nil : uri
        }

        return urisByName
    }

    private func parseDetail(from output: String) -> PrinterQueueDetail {
        var rawStatusLine = ""
        var attributes: [String: String] = [:]
        var listAttributes: [String: [String]] = [:]
        var flags: [String] = []
        var currentListKey: String?

        for (index, rawLine) in output.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine)

            if index == 0 {
                rawStatusLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                currentListKey = nil
                continue
            }

            let indentationCount = line.prefix { $0 == "\t" || $0 == " " }.count
            if indentationCount >= 2, let currentListKey {
                listAttributes[currentListKey, default: []].append(trimmed)
                continue
            }

            currentListKey = nil

            if let separator = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<separator])
                let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                attributes[key] = value

                if value.isEmpty {
                    listAttributes[key] = listAttributes[key] ?? []
                    currentListKey = key
                }
            } else {
                flags.append(trimmed)
            }
        }

        listAttributes = listAttributes.filter { !$0.value.isEmpty }

        return PrinterQueueDetail(
            rawStatusLine: rawStatusLine,
            attributes: attributes,
            listAttributes: listAttributes,
            flags: flags
        )
    }

    private func parseOptions(from output: String) -> [PrinterOption] {
        output
            .split(separator: "\n")
            .compactMap { rawLine in
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return nil }
                guard let separator = line.firstIndex(of: ":") else { return nil }

                let keyPart = String(line[..<separator])
                let valuePart = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)

                let optionKey: String
                let displayName: String
                if let slash = keyPart.firstIndex(of: "/") {
                    optionKey = String(keyPart[..<slash])
                    displayName = String(keyPart[keyPart.index(after: slash)...])
                } else {
                    optionKey = keyPart
                    displayName = keyPart
                }

                let values = valuePart.split(separator: " ").map { rawValue -> PrinterOptionChoice in
                    let token = String(rawValue)
                    if token.hasPrefix("*") {
                        return PrinterOptionChoice(value: String(token.dropFirst()), isDefault: true)
                    }

                    return PrinterOptionChoice(value: token, isDefault: false)
                }

                return PrinterOption(key: optionKey, displayName: displayName, values: values)
            }
    }

    private func parseStateLine(_ line: String) -> (name: String, status: String, stateDetail: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("printer ") else { return nil }

        let printerPrefixLength = "printer ".count
        let contentStart = trimmed.index(trimmed.startIndex, offsetBy: printerPrefixLength)
        let content = String(trimmed[contentStart...])

        guard let isRange = content.range(of: " is ") else { return nil }
        let name = String(content[..<isRange.lowerBound])
        let remainder = String(content[isRange.upperBound...])

        let parts = remainder.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let status = parts.first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "unknown"
        let stateDetail = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        return (name, status, stateDetail?.isEmpty == true ? nil : stateDetail)
    }
}
