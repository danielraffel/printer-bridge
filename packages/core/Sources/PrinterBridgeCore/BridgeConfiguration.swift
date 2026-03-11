import Foundation

public enum BridgeExposureMode: String, Codable, Equatable, Sendable {
    case directCUPS = "direct-cups"
    case proxy = "proxy"
}

public struct ManagedPrinterConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var queueName: String
    public var isEnabled: Bool
    public var advertisedNameOverride: String?
    public var proxyPort: Int?

    public var id: String { queueName }

    public init(
        queueName: String,
        isEnabled: Bool = false,
        advertisedNameOverride: String? = nil,
        proxyPort: Int? = nil
    ) {
        self.queueName = queueName
        self.isEnabled = isEnabled
        self.advertisedNameOverride = advertisedNameOverride
        self.proxyPort = proxyPort
    }
}

public struct BridgeConfiguration: Codable, Equatable, Sendable {
    public var selectedQueueName: String?
    public var printers: [ManagedPrinterConfiguration]
    public var exposureMode: BridgeExposureMode
    public var keepRunningInBackground: Bool

    enum CodingKeys: String, CodingKey {
        case selectedQueueName
        case printers
        case exposureMode
        case keepRunningInBackground
        case isEnabled
        case advertisedNameOverride
    }

    public init(
        selectedQueueName: String? = ProjectMetadata.primaryTargetPrinter,
        printers: [ManagedPrinterConfiguration] = [],
        exposureMode: BridgeExposureMode = .proxy,
        keepRunningInBackground: Bool = true
    ) {
        self.selectedQueueName = selectedQueueName
        self.printers = printers
        self.exposureMode = exposureMode
        self.keepRunningInBackground = keepRunningInBackground
        normalize()
    }

    public init(
        isEnabled: Bool,
        selectedQueueName: String? = ProjectMetadata.primaryTargetPrinter,
        advertisedNameOverride: String? = nil,
        exposureMode: BridgeExposureMode = .proxy,
        keepRunningInBackground: Bool = true
    ) {
        let printers = selectedQueueName.map {
            [
                ManagedPrinterConfiguration(
                    queueName: $0,
                    isEnabled: isEnabled,
                    advertisedNameOverride: advertisedNameOverride,
                    proxyPort: ProjectMetadata.defaultProxyPort
                )
            ]
        } ?? []

        self.init(
            selectedQueueName: selectedQueueName,
            printers: printers,
            exposureMode: exposureMode,
            keepRunningInBackground: keepRunningInBackground
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        selectedQueueName = try container.decodeIfPresent(String.self, forKey: .selectedQueueName)
        printers = try container.decodeIfPresent([ManagedPrinterConfiguration].self, forKey: .printers) ?? []
        exposureMode = try container.decodeIfPresent(BridgeExposureMode.self, forKey: .exposureMode) ?? .proxy
        keepRunningInBackground = try container.decodeIfPresent(Bool.self, forKey: .keepRunningInBackground) ?? true

        if printers.isEmpty, let selectedQueueName, !selectedQueueName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let legacyIsEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
            let legacyAdvertisedNameOverride = try container.decodeIfPresent(String.self, forKey: .advertisedNameOverride)
            printers = [
                ManagedPrinterConfiguration(
                    queueName: selectedQueueName,
                    isEnabled: legacyIsEnabled,
                    advertisedNameOverride: legacyAdvertisedNameOverride,
                    proxyPort: ProjectMetadata.defaultProxyPort
                )
            ]
        }

        normalize()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(selectedQueueName, forKey: .selectedQueueName)
        try container.encode(printers, forKey: .printers)
        try container.encode(exposureMode, forKey: .exposureMode)
        try container.encode(keepRunningInBackground, forKey: .keepRunningInBackground)
    }

    public var isEnabled: Bool {
        get {
            managedPrinter(queueName: selectedQueueName)?.isEnabled ?? false
        }
        set {
            guard let selectedQueueName else {
                return
            }

            setEnabled(newValue, forQueueNamed: selectedQueueName)
        }
    }

    public var advertisedNameOverride: String? {
        get {
            managedPrinter(queueName: selectedQueueName)?.advertisedNameOverride
        }
        set {
            guard let selectedQueueName else {
                return
            }

            setAdvertisedNameOverride(newValue, forQueueNamed: selectedQueueName)
        }
    }

    public var enabledPrinters: [ManagedPrinterConfiguration] {
        printers.filter(\.isEnabled)
    }

    public func managedPrinter(queueName: String?) -> ManagedPrinterConfiguration? {
        guard let queueName else {
            return nil
        }

        return printers.first(where: { $0.queueName == queueName })
    }

    public mutating func ensureManagedPrinter(forQueueNamed queueName: String) {
        let trimmedQueueName = queueName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQueueName.isEmpty else {
            return
        }

        if printers.contains(where: { $0.queueName == trimmedQueueName }) {
            return
        }

        printers.append(
            ManagedPrinterConfiguration(
                queueName: trimmedQueueName,
                proxyPort: nextAvailableProxyPort()
            )
        )
        normalize()
    }

    public mutating func setEnabled(_ enabled: Bool, forQueueNamed queueName: String) {
        ensureManagedPrinter(forQueueNamed: queueName)
        guard let index = printers.firstIndex(where: { $0.queueName == queueName }) else {
            return
        }

        printers[index].isEnabled = enabled
        if printers[index].proxyPort == nil {
            printers[index].proxyPort = nextAvailableProxyPort(excludingQueueName: queueName)
        }
        normalize()
    }

    public mutating func setAdvertisedNameOverride(_ value: String?, forQueueNamed queueName: String) {
        ensureManagedPrinter(forQueueNamed: queueName)
        guard let index = printers.firstIndex(where: { $0.queueName == queueName }) else {
            return
        }

        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        printers[index].advertisedNameOverride = trimmedValue?.isEmpty == true ? nil : trimmedValue
        normalize()
    }

    public mutating func setSelectedQueueName(_ queueName: String?) {
        selectedQueueName = queueName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let selectedQueueName, !selectedQueueName.isEmpty {
            ensureManagedPrinter(forQueueNamed: selectedQueueName)
        }
        normalize()
    }

    public mutating func ensureFocusedQueue(fallbackQueueName: String?) {
        if let selectedQueueName, !selectedQueueName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ensureManagedPrinter(forQueueNamed: selectedQueueName)
            normalize()
            return
        }

        if let fallbackQueueName, !fallbackQueueName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setSelectedQueueName(fallbackQueueName)
            return
        }

        if let firstConfiguredQueueName = printers.first?.queueName {
            selectedQueueName = firstConfiguredQueueName
        }
        normalize()
    }

    public func nextAvailableProxyPort(excludingQueueName queueName: String? = nil) -> Int {
        var usedPorts = Set<Int>()
        for printer in printers {
            if printer.queueName == queueName {
                continue
            }

            if let proxyPort = printer.proxyPort {
                usedPorts.insert(proxyPort)
            }
        }

        var candidate = ProjectMetadata.defaultProxyPort
        while usedPorts.contains(candidate) {
            candidate += 1
        }

        return candidate
    }

    public mutating func normalize() {
        selectedQueueName = selectedQueueName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedQueueName?.isEmpty == true {
            selectedQueueName = nil
        }

        var normalizedPrinters: [ManagedPrinterConfiguration] = []
        for printer in printers {
            let queueName = printer.queueName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !queueName.isEmpty else {
                continue
            }

            if normalizedPrinters.contains(where: { $0.queueName == queueName }) {
                continue
            }

            let advertisedNameOverride = printer.advertisedNameOverride?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            normalizedPrinters.append(
                ManagedPrinterConfiguration(
                    queueName: queueName,
                    isEnabled: printer.isEnabled,
                    advertisedNameOverride: advertisedNameOverride?.isEmpty == true ? nil : advertisedNameOverride,
                    proxyPort: printer.proxyPort
                )
            )
        }

        var usedPorts = Set<Int>()
        for index in normalizedPrinters.indices {
            let currentPort = normalizedPrinters[index].proxyPort
            let isValidPort = currentPort.map { $0 > 0 && $0 < 65536 } ?? false
            if let currentPort, isValidPort, !usedPorts.contains(currentPort) {
                usedPorts.insert(currentPort)
                continue
            }

            var candidate = ProjectMetadata.defaultProxyPort
            while usedPorts.contains(candidate) {
                candidate += 1
            }
            normalizedPrinters[index].proxyPort = candidate
            usedPorts.insert(candidate)
        }

        printers = normalizedPrinters.sorted { lhs, rhs in
            lhs.queueName.localizedCaseInsensitiveCompare(rhs.queueName) == .orderedAscending
        }
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
