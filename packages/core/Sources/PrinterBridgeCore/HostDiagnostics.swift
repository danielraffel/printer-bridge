import Foundation

public enum DiagnosticStatus: String {
    case ok = "ok"
    case warning = "warning"
    case error = "error"
}

public struct DiagnosticSection: Equatable {
    public let title: String
    public let commandDescription: String?
    public let status: DiagnosticStatus
    public let output: String

    public init(title: String, commandDescription: String?, status: DiagnosticStatus, output: String) {
        self.title = title
        self.commandDescription = commandDescription
        self.status = status
        self.output = output
    }
}

public struct DiagnosticReport: Equatable {
    public let title: String
    public let summary: [String]
    public let sections: [DiagnosticSection]

    public init(title: String, summary: [String], sections: [DiagnosticSection]) {
        self.title = title
        self.summary = summary
        self.sections = sections
    }

    public var success: Bool {
        !sections.contains { $0.status == .error }
    }

    public var renderedText: String {
        var lines = [title, ""]

        if !summary.isEmpty {
            lines.append("Summary")
            lines.append(contentsOf: summary.map { "- \($0)" })
            lines.append("")
        }

        for (index, section) in sections.enumerated() {
            lines.append("[\(section.status.rawValue.uppercased())] \(section.title)")
            if let commandDescription = section.commandDescription {
                lines.append("command: \(commandDescription)")
            }

            let body = section.output.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(body.isEmpty ? "(no output)" : body)

            if index < sections.count - 1 {
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }
}

public struct HostDiagnosticsService {
    private let runner: any CommandRunning
    private let fileManager: FileManager

    public init(runner: any CommandRunning = ProcessCommandRunner(), fileManager: FileManager = .default) {
        self.runner = runner
        self.fileManager = fileManager
    }

    public func doctor(printerName: String? = ProjectMetadata.primaryTargetPrinter) -> DiagnosticReport {
        let targetPrinter = printerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultPrinter = runRequired("Default Printer", executable: SystemTool.lpstat.path, arguments: ["-d"])
        let printerList = listPrintersSection()
        let services = listServicesSection()

        var sections = [
            hostSection(),
            commandAvailabilitySection(),
            defaultPrinter,
            printerList,
            services.universal,
            services.general,
        ]

        if let targetPrinter, !targetPrinter.isEmpty {
            sections.append(inspectPrinterSection(named: targetPrinter))
        }

        var summary = [
            "product: \(ProjectMetadata.productName)",
            "minimum macOS: \(ProjectMetadata.minimumSupportedMacOS)+",
            "verification host alias: \(ProjectMetadata.verificationHostAlias)",
        ]

        if let defaultQueue = parseDefaultPrinter(from: defaultPrinter.output) {
            summary.append("default printer: \(defaultQueue)")
        }

        if let targetPrinter, !targetPrinter.isEmpty {
            summary.append("target printer: \(targetPrinter)")
        }

        let universalCount = nonEmptyLineCount(in: services.universal.output)
        let generalCount = nonEmptyLineCount(in: services.general.output)
        summary.append("discovered AirPrint-style services: \(universalCount)")
        summary.append("discovered IPP services: \(generalCount)")

        if services.universal.output.contains(":10631") {
            summary.append("legacy bridge endpoint detected on port 10631")
        }

        return DiagnosticReport(
            title: "PrinterBridge doctor",
            summary: summary,
            sections: sections
        )
    }

    public func listPrintersReport() -> DiagnosticReport {
        let printers = listPrintersSection()

        return DiagnosticReport(
            title: "PrinterBridge printers",
            summary: [
                "configured queues: \(queueCount(in: printers.output))",
            ],
            sections: [printers]
        )
    }

    public func inspectPrinterReport(named printerName: String) -> DiagnosticReport {
        let section = inspectPrinterSection(named: printerName)

        return DiagnosticReport(
            title: "PrinterBridge printer inspection",
            summary: ["target printer: \(printerName)"],
            sections: [section]
        )
    }

    public func listServicesReport() -> DiagnosticReport {
        let services = listServicesSection()

        return DiagnosticReport(
            title: "PrinterBridge service discovery",
            summary: [
                "AirPrint-style services: \(nonEmptyLineCount(in: services.universal.output))",
                "IPP services: \(nonEmptyLineCount(in: services.general.output))",
            ],
            sections: [services.universal, services.general]
        )
    }

    private func hostSection() -> DiagnosticSection {
        let version = runRequired("macOS Version", executable: SystemTool.swVers.path, arguments: [])
        let arch = runRequired("Architecture", executable: SystemTool.uname.path, arguments: ["-m"])

        let output = """
        \(version.output.trimmingCharacters(in: .whitespacesAndNewlines))

        \(arch.output.trimmingCharacters(in: .whitespacesAndNewlines))
        """

        let status: DiagnosticStatus = version.status == .error || arch.status == .error ? .error : .ok
        return DiagnosticSection(title: "Host", commandDescription: nil, status: status, output: output)
    }

    private func commandAvailabilitySection() -> DiagnosticSection {
        let lines = SystemTool.allCases.map { command in
            let available = fileManager.isExecutableFile(atPath: command.path)
            let marker = available ? "available" : "missing"
            let requirement = command.isRequired ? "required" : "optional"
            return "\(URL(fileURLWithPath: command.path).lastPathComponent): \(marker) (\(requirement))"
        }

        let missingRequired = SystemTool.allCases.contains { command in
            command.isRequired && !fileManager.isExecutableFile(atPath: command.path)
        }

        return DiagnosticSection(
            title: "Tool Availability",
            commandDescription: nil,
            status: missingRequired ? .error : .ok,
            output: lines.joined(separator: "\n")
        )
    }

    private func listPrintersSection() -> DiagnosticSection {
        let printerState = runRequired("Configured Printers", executable: SystemTool.lpstat.path, arguments: ["-p"])
        let printerURIs = runRequired("Printer URIs", executable: SystemTool.lpstat.path, arguments: ["-v"])

        let output = """
        \(printerState.output.trimmingCharacters(in: .whitespacesAndNewlines))

        \(printerURIs.output.trimmingCharacters(in: .whitespacesAndNewlines))
        """

        let status: DiagnosticStatus = printerState.status == .error || printerURIs.status == .error ? .error : .ok
        return DiagnosticSection(title: "Configured Printers", commandDescription: nil, status: status, output: output)
    }

    private func inspectPrinterSection(named printerName: String) -> DiagnosticSection {
        let details = runOptional(
            "Printer Detail",
            executable: SystemTool.lpstat.path,
            arguments: ["-l", "-p", printerName]
        )
        let options = runOptional(
            "Printer Options",
            executable: SystemTool.lpoptions.path,
            arguments: ["-p", printerName, "-l"]
        )

        let output = """
        \(details.output.trimmingCharacters(in: .whitespacesAndNewlines))

        \(options.output.trimmingCharacters(in: .whitespacesAndNewlines))
        """

        let status: DiagnosticStatus
        if details.status == .ok || options.status == .ok {
            status = .ok
        } else {
            status = .warning
        }

        return DiagnosticSection(
            title: "Printer Detail (\(printerName))",
            commandDescription: nil,
            status: status,
            output: output
        )
    }

    private func listServicesSection() -> (universal: DiagnosticSection, general: DiagnosticSection) {
        let universal = runOptional(
            "AirPrint-Style Services",
            executable: SystemTool.ippfind.path,
            arguments: ["-T", "2", "_ipp._tcp,_universal", "--print"]
        )
        let general = runOptional(
            "IPP Services",
            executable: SystemTool.ippfind.path,
            arguments: ["-T", "2", "_ipp._tcp", "--print"]
        )

        return (universal, general)
    }

    private func runRequired(_ title: String, executable: String, arguments: [String]) -> DiagnosticSection {
        let result = runner.run(executable: executable, arguments: arguments)
        let status: DiagnosticStatus = result.exitCode == 0 ? .ok : .error
        let output = result.combinedOutput.isEmpty ? "(no output)" : result.combinedOutput

        return DiagnosticSection(
            title: title,
            commandDescription: result.commandDescription,
            status: status,
            output: output
        )
    }

    private func runOptional(_ title: String, executable: String, arguments: [String]) -> DiagnosticSection {
        let result = runner.run(executable: executable, arguments: arguments)
        let status: DiagnosticStatus = result.exitCode == 0 ? .ok : .warning
        let output = result.combinedOutput.isEmpty ? "(no output)" : result.combinedOutput

        return DiagnosticSection(
            title: title,
            commandDescription: result.commandDescription,
            status: status,
            output: output
        )
    }

    private func parseDefaultPrinter(from output: String) -> String? {
        output
            .split(separator: "\n")
            .first?
            .split(separator: ":", maxSplits: 1)
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func queueCount(in output: String) -> Int {
        output
            .split(separator: "\n")
            .filter { $0.hasPrefix("printer ") }
            .count
    }

    private func nonEmptyLineCount(in output: String) -> Int {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "(no output)" }
            .count
    }
}
