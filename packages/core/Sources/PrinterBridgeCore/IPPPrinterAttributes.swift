import Foundation

public struct IPPAttribute: Equatable, Sendable {
    public let name: String
    public let valueType: String
    public let rawValue: String

    public init(name: String, valueType: String, rawValue: String) {
        self.name = name
        self.valueType = valueType
        self.rawValue = rawValue
    }

    public var values: [String] {
        Self.splitTopLevelCSV(rawValue)
    }

    public var boolValue: Bool? {
        switch rawValue.lowercased() {
        case "true":
            return true
        case "false":
            return false
        default:
            return nil
        }
    }

    public var intValue: Int? {
        Int(rawValue)
    }

    private static func splitTopLevelCSV(_ rawValue: String) -> [String] {
        var values: [String] = []
        var current = ""
        var braceDepth = 0

        for character in rawValue {
            switch character {
            case "{":
                braceDepth += 1
                current.append(character)
            case "}":
                braceDepth = max(0, braceDepth - 1)
                current.append(character)
            case "," where braceDepth == 0:
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    values.append(trimmed)
                }
                current = ""
            default:
                current.append(character)
            }
        }

        let trailing = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty {
            values.append(trailing)
        }

        return values
    }
}

public struct IPPPrinterAttributesSnapshot: Equatable, Sendable {
    public let queueName: String
    public let printerURI: String
    public let attributes: [String: IPPAttribute]
    public let rawOutput: String

    public init(
        queueName: String,
        printerURI: String,
        attributes: [String: IPPAttribute],
        rawOutput: String
    ) {
        self.queueName = queueName
        self.printerURI = printerURI
        self.attributes = attributes
        self.rawOutput = rawOutput
    }

    public func attribute(named name: String) -> IPPAttribute? {
        attributes[name]
    }

    public func stringValue(named name: String) -> String? {
        attribute(named: name)?.rawValue
    }

    public func boolValue(named name: String) -> Bool? {
        attribute(named: name)?.boolValue
    }

    public func intValue(named name: String) -> Int? {
        attribute(named: name)?.intValue
    }

    public func values(named name: String) -> [String] {
        attribute(named: name)?.values ?? []
    }
}

public struct IPPPrinterAttributeService {
    public static let defaultTestFilePath = "/usr/share/cups/ipptool/get-printer-attributes.test"

    private let runner: any CommandRunning
    private let testFilePath: String

    public init(
        runner: any CommandRunning = ProcessCommandRunner(),
        testFilePath: String = IPPPrinterAttributeService.defaultTestFilePath
    ) {
        self.runner = runner
        self.testFilePath = testFilePath
    }

    public func fetchAttributes(forQueueNamed queueName: String) -> IPPPrinterAttributesSnapshot? {
        let encodedQueueName = queueName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? queueName
        let printerURI = "ipp://localhost:631/printers/\(encodedQueueName)"
        let result = runner.run(
            executable: SystemTool.ipptool.path,
            arguments: ["-tv", printerURI, testFilePath]
        )

        guard result.exitCode == 0 else {
            return nil
        }

        return IPPPrinterAttributesSnapshot(
            queueName: queueName,
            printerURI: printerURI,
            attributes: parseAttributes(from: result.combinedOutput),
            rawOutput: result.combinedOutput
        )
    }

    public func renderAttributes(forQueueNamed queueName: String) -> String {
        guard let snapshot = fetchAttributes(forQueueNamed: queueName) else {
            return """
            PrinterBridge IPP attribute inspection

            Summary
            - target printer: \(queueName)
            - result: failed to read IPP attributes
            """
        }

        var lines = [
            "PrinterBridge IPP attribute inspection",
            "",
            "Summary",
            "- target printer: \(snapshot.queueName)",
            "- attribute count: \(snapshot.attributes.count)",
            "- printer URI: \(snapshot.printerURI)",
            "",
            "Attributes",
        ]

        for key in snapshot.attributes.keys.sorted() {
            guard let attribute = snapshot.attributes[key] else {
                continue
            }

            lines.append("- \(attribute.name) (\(attribute.valueType)): \(attribute.rawValue)")
        }

        return lines.joined(separator: "\n")
    }

    private func parseAttributes(from output: String) -> [String: IPPAttribute] {
        var attributes: [String: IPPAttribute] = [:]

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else {
                continue
            }

            guard
                let nameRange = trimmedLine.range(of: " ("),
                let separatorRange = trimmedLine.range(of: ") = ")
            else {
                continue
            }

            let name = String(trimmedLine[..<nameRange.lowerBound])
            let valueType = String(trimmedLine[nameRange.upperBound..<separatorRange.lowerBound])
            let rawValue = String(trimmedLine[separatorRange.upperBound...])

            attributes[name] = IPPAttribute(name: name, valueType: valueType, rawValue: rawValue)
        }

        return attributes
    }
}
