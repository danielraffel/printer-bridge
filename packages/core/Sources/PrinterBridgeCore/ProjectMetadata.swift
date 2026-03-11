import Foundation

public enum ProjectMetadata {
    public static let productName = "PrinterBridge"
    public static let repositorySlug = "printer-bridge"
    public static let minimumSupportedMacOS = "15.0"
    public static let verificationHostAlias = "macmini"
    public static let primaryTargetPrinter = "Brother_HL_2170W_series"
    public static let defaultProxyPort = 8631
    public static let developmentHostDescription = "Apple Silicon MacBook Pro running macOS 26.x"
    public static let verificationHostDescription = "Intel Mac mini running macOS 15.7.4"
}

public struct HostTarget: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let accessCommand: String?

    public init(id: String, name: String, description: String, accessCommand: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.accessCommand = accessCommand
    }
}

public enum DevelopmentTopology {
    public static let hosts: [HostTarget] = [
        HostTarget(
            id: "dev-machine",
            name: "Development Machine",
            description: ProjectMetadata.developmentHostDescription
        ),
        HostTarget(
            id: "verification-host",
            name: "Verification Host",
            description: ProjectMetadata.verificationHostDescription,
            accessCommand: "ssh \(ProjectMetadata.verificationHostAlias)"
        ),
    ]
}

public enum ProjectRoadmap {
    public static let nearTerm: [String] = [
        "Implement printer discovery through CUPS",
        "Replace daemon placeholder with helper lifecycle and XPC",
        "Add deploy and validation loops for the macmini host",
        "Begin protocol-level AirPrint advertisement verification",
    ]
}

public struct SmokeTestResult: Sendable {
    public let success: Bool
    public let output: String

    public init(success: Bool, output: String) {
        self.success = success
        self.output = output
    }
}

public enum ProjectDiagnostics {
    public static let overviewText = """
        \(ProjectMetadata.productName)
        repo: \(ProjectMetadata.repositorySlug)
        minimum macOS: \(ProjectMetadata.minimumSupportedMacOS)
        verification host alias: \(ProjectMetadata.verificationHostAlias)
        primary target printer: \(ProjectMetadata.primaryTargetPrinter)
        """

    public static let hostsText = DevelopmentTopology.hosts
        .map { host in
            if let accessCommand = host.accessCommand {
                return "\(host.name): \(host.description) [\(accessCommand)]"
            }

            return "\(host.name): \(host.description)"
        }
        .joined(separator: "\n")

    public static let roadmapText = ProjectRoadmap.nearTerm
        .enumerated()
        .map { index, item in "\(index + 1). \(item)" }
        .joined(separator: "\n")

    public static func smokeTest() -> SmokeTestResult {
        let hasMinimumVersion = ProjectMetadata.minimumSupportedMacOS == "15.0"
        let hasVerificationAlias = ProjectMetadata.verificationHostAlias == "macmini"
        let hasPrimaryTargetPrinter = ProjectMetadata.primaryTargetPrinter == "Brother_HL_2170W_series"
        let hasHosts = DevelopmentTopology.hosts.count == 2

        let success = hasMinimumVersion && hasVerificationAlias && hasPrimaryTargetPrinter && hasHosts
        let output = """
        smoke test: \(success ? "passed" : "failed")
        minimum macOS: \(ProjectMetadata.minimumSupportedMacOS)
        verification alias: \(ProjectMetadata.verificationHostAlias)
        primary target printer: \(ProjectMetadata.primaryTargetPrinter)
        host count: \(DevelopmentTopology.hosts.count)
        """

        return SmokeTestResult(success: success, output: output)
    }
}
