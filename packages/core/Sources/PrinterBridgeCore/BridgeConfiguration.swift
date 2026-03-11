import Foundation

public enum BridgeExposureMode: String, Codable, Equatable, Sendable {
    case directCUPS = "direct-cups"
    case proxy = "proxy"
}

public struct BridgeConfiguration: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var selectedQueueName: String?
    public var advertisedNameOverride: String?
    public var exposureMode: BridgeExposureMode
    public var keepRunningInBackground: Bool

    public init(
        isEnabled: Bool = false,
        selectedQueueName: String? = ProjectMetadata.primaryTargetPrinter,
        advertisedNameOverride: String? = nil,
        exposureMode: BridgeExposureMode = .proxy,
        keepRunningInBackground: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.selectedQueueName = selectedQueueName
        self.advertisedNameOverride = advertisedNameOverride
        self.exposureMode = exposureMode
        self.keepRunningInBackground = keepRunningInBackground
    }
}

public struct BridgeConfigurationStore {
    public static let environmentOverrideKey = "PRINTERBRIDGE_CONFIG_PATH"

    private let fileManager: FileManager
    public let configURL: URL

    public init(
        fileManager: FileManager = .default,
        configURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.configURL = configURL ?? Self.defaultConfigURL(fileManager: fileManager, environment: environment)
    }

    public func load() throws -> BridgeConfiguration {
        guard fileManager.fileExists(atPath: configURL.path) else {
            return BridgeConfiguration()
        }

        let data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(BridgeConfiguration.self, from: data)
    }

    public func save(_ configuration: BridgeConfiguration) throws {
        let parentDirectory = configURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)

        let data = try JSONEncoder.prettyPrinted.encode(configuration)
        try data.write(to: configURL, options: .atomic)
    }

    public static func defaultConfigURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let overridePath = environment[environmentOverrideKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !overridePath.isEmpty {
            let expandedPath = (overridePath as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expandedPath, isDirectory: false)
        }

        let applicationSupport = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(ProjectMetadata.productName, isDirectory: true)

        return applicationSupport.appendingPathComponent("bridge-config.json", isDirectory: false)
    }
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
