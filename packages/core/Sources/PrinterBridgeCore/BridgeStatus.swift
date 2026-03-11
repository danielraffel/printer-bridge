import Foundation
import SystemConfiguration

public enum BridgeActivationState: String, Equatable, Sendable {
    case disabled = "disabled"
    case ready = "ready"
    case needsReview = "needs-review"
    case unavailable = "unavailable"
}

public struct AirPrintAdvertisementPlan: Equatable, Sendable {
    public struct TXTRecord: Equatable, Sendable {
        public let key: String
        public let value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    public let serviceName: String
    public let hostName: String
    public let port: Int
    public let resourcePath: String
    public let printerURI: String
    public let backingQueueName: String
    public let exposureMode: BridgeExposureMode
    public let txtRecords: [TXTRecord]
    public let warnings: [String]

    public init(
        serviceName: String,
        hostName: String,
        port: Int,
        resourcePath: String,
        printerURI: String,
        backingQueueName: String,
        exposureMode: BridgeExposureMode,
        txtRecords: [TXTRecord],
        warnings: [String]
    ) {
        self.serviceName = serviceName
        self.hostName = hostName
        self.port = port
        self.resourcePath = resourcePath
        self.printerURI = printerURI
        self.backingQueueName = backingQueueName
        self.exposureMode = exposureMode
        self.txtRecords = txtRecords
        self.warnings = warnings
    }
}

public struct BridgeStatusSnapshot: Equatable, Sendable {
    public let configuration: BridgeConfiguration
    public let availableQueues: [PrinterQueueSummary]
    public let selectedQueue: PrinterQueueInspection?
    public let activationState: BridgeActivationState
    public let message: String
    public let advertisement: AirPrintAdvertisementPlan?

    public init(
        configuration: BridgeConfiguration,
        availableQueues: [PrinterQueueSummary],
        selectedQueue: PrinterQueueInspection?,
        activationState: BridgeActivationState,
        message: String,
        advertisement: AirPrintAdvertisementPlan?
    ) {
        self.configuration = configuration
        self.availableQueues = availableQueues
        self.selectedQueue = selectedQueue
        self.activationState = activationState
        self.message = message
        self.advertisement = advertisement
    }

    public var isPublishable: Bool {
        configuration.isEnabled && activationState == .ready && advertisement != nil
    }
}

public struct BridgeStatusService {
    private let inventoryService: PrinterInventoryService
    private let attributeService: IPPPrinterAttributeService
    private let hostNameProvider: () -> String

    public init(
        inventoryService: PrinterInventoryService = PrinterInventoryService(),
        attributeService: IPPPrinterAttributeService = IPPPrinterAttributeService(),
        hostNameProvider: @escaping () -> String = { BridgeStatusService.defaultHostName() }
    ) {
        self.inventoryService = inventoryService
        self.attributeService = attributeService
        self.hostNameProvider = hostNameProvider
    }

    public func evaluate(configuration: BridgeConfiguration) -> BridgeStatusSnapshot {
        let normalizedConfiguration = normalized(configuration: configuration)
        let availableQueues = inventoryService.listQueues()
        let selectedQueue = normalizedConfiguration.selectedQueueName.flatMap { inventoryService.inspectQueue(named: $0) }

        guard normalizedConfiguration.isEnabled else {
            let attributes = selectedQueue.flatMap { attributeService.fetchAttributes(forQueueNamed: $0.summary.name) }
            return BridgeStatusSnapshot(
                configuration: normalizedConfiguration,
                availableQueues: availableQueues,
                selectedQueue: selectedQueue,
                activationState: .disabled,
                message: "Bridge is disabled.",
                advertisement: selectedQueue.flatMap {
                    makeAdvertisementPlan(
                        for: $0,
                        attributes: attributes,
                        configuration: normalizedConfiguration
                    )
                }
            )
        }

        guard let selectedQueue else {
            return BridgeStatusSnapshot(
                configuration: normalizedConfiguration,
                availableQueues: availableQueues,
                selectedQueue: nil,
                activationState: .unavailable,
                message: "The selected printer queue is not available on this Mac.",
                advertisement: nil
            )
        }

        let attributes = attributeService.fetchAttributes(forQueueNamed: selectedQueue.summary.name)
        let advertisement = makeAdvertisementPlan(
            for: selectedQueue,
            attributes: attributes,
            configuration: normalizedConfiguration
        )
        let activationState: BridgeActivationState
        if selectedQueue.suitability == .needsReview || !advertisement.warnings.isEmpty {
            activationState = .needsReview
        } else {
            activationState = .ready
        }
        let message: String
        switch activationState {
        case .ready:
            message = "Bridge can advertise the selected CUPS queue."
        case .needsReview:
            message = "Bridge is enabled, but the selected queue needs additional validation before it is publishable."
        case .disabled, .unavailable:
            message = ""
        }

        return BridgeStatusSnapshot(
            configuration: normalizedConfiguration,
            availableQueues: availableQueues,
            selectedQueue: selectedQueue,
            activationState: activationState,
            message: message,
            advertisement: advertisement
        )
    }

    public func renderStatus(configuration: BridgeConfiguration) -> String {
        let snapshot = evaluate(configuration: configuration)
        var lines = [
            "PrinterBridge bridge status",
            "",
            "Summary",
            "- state: \(snapshot.activationState.rawValue)",
            "- enabled: \(snapshot.configuration.isEnabled ? "yes" : "no")",
            "- publishable: \(snapshot.isPublishable ? "yes" : "no")",
            "- exposure mode: \(snapshot.configuration.exposureMode.rawValue)",
            "- queues detected: \(snapshot.availableQueues.count)",
            "- message: \(snapshot.message)",
        ]

        if let selectedQueueName = snapshot.configuration.selectedQueueName, !selectedQueueName.isEmpty {
            lines.append("- selected queue: \(selectedQueueName)")
        }

        if let advertisedNameOverride = snapshot.configuration.advertisedNameOverride, !advertisedNameOverride.isEmpty {
            lines.append("- advertised name override: \(advertisedNameOverride)")
        }

        if let selectedQueue = snapshot.selectedQueue {
            lines.append("- queue suitability: \(selectedQueue.suitability.rawValue)")
        }

        if let advertisement = snapshot.advertisement {
            lines.append("")
            lines.append("Advertisement Plan")
            lines.append("- service name: \(advertisement.serviceName)")
            lines.append("- host: \(advertisement.hostName)")
            lines.append("- printer URI: \(advertisement.printerURI)")
            lines.append("- resource path: \(advertisement.resourcePath)")
            lines.append("- backing queue: \(advertisement.backingQueueName)")

            if !advertisement.txtRecords.isEmpty {
                lines.append("")
                lines.append("TXT Records")
                for record in advertisement.txtRecords {
                    lines.append("- \(record.key)=\(record.value)")
                }
            }

            if !advertisement.warnings.isEmpty {
                lines.append("")
                lines.append("Warnings")
                for warning in advertisement.warnings {
                    lines.append("- \(warning)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private func normalized(configuration: BridgeConfiguration) -> BridgeConfiguration {
        var configuration = configuration
        if let selectedQueueName = configuration.selectedQueueName?.trimmingCharacters(in: .whitespacesAndNewlines) {
            configuration.selectedQueueName = selectedQueueName.isEmpty ? nil : selectedQueueName
        }

        if let advertisedNameOverride = configuration.advertisedNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines) {
            configuration.advertisedNameOverride = advertisedNameOverride.isEmpty ? nil : advertisedNameOverride
        }

        return configuration
    }

    private func makeAdvertisementPlan(
        for inspection: PrinterQueueInspection,
        attributes: IPPPrinterAttributesSnapshot?,
        configuration: BridgeConfiguration
    ) -> AirPrintAdvertisementPlan {
        let hostName = hostNameProvider()
        let baseServiceName = inspection.detail.description
            ?? inspection.summary.name.replacingOccurrences(of: "_", with: " ")
        let serviceName = configuration.advertisedNameOverride
            ?? "\(baseServiceName) via \(ProjectMetadata.productName)"

        let encodedQueueName = inspection.summary.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? inspection.summary.name
        let resourcePath = "/printers/\(encodedQueueName)"
        let port = advertisedPort(for: configuration.exposureMode)
        let printerURI = "ipp://\(hostName):\(port)\(resourcePath)"
        let txtRecords = makeTXTRecords(
            serviceName: serviceName,
            hostName: hostName,
            resourcePath: resourcePath,
            inspection: inspection,
            attributes: attributes
        )
        let warnings = makeWarnings(
            inspection: inspection,
            attributes: attributes,
            txtRecords: txtRecords,
            exposureMode: configuration.exposureMode
        )

        return AirPrintAdvertisementPlan(
            serviceName: serviceName,
            hostName: hostName,
            port: port,
            resourcePath: resourcePath,
            printerURI: printerURI,
            backingQueueName: inspection.summary.name,
            exposureMode: configuration.exposureMode,
            txtRecords: txtRecords,
            warnings: warnings
        )
    }

    private func advertisedPort(for exposureMode: BridgeExposureMode) -> Int {
        switch exposureMode {
        case .directCUPS:
            return 631
        case .proxy:
            return ProjectMetadata.defaultProxyPort
        }
    }

    private func makeTXTRecords(
        serviceName: String,
        hostName: String,
        resourcePath: String,
        inspection: PrinterQueueInspection,
        attributes: IPPPrinterAttributesSnapshot?
    ) -> [AirPrintAdvertisementPlan.TXTRecord] {
        let rpValue = resourcePath.hasPrefix("/") ? String(resourcePath.dropFirst()) : resourcePath
        let printerInfo = attributes?.stringValue(named: "printer-info")
            ?? inspection.detail.description
            ?? serviceName
        let makeAndModel = attributes?.stringValue(named: "printer-make-and-model")
            ?? inspection.detail.description
            ?? serviceName
        let documentFormats = supportedDocumentFormats(from: attributes)
        let colorValue = (attributes?.boolValue(named: "color-supported") ?? false) ? "T" : "F"
        let duplexValue = supportsDuplex(attributes: attributes, inspection: inspection) ? "T" : "F"

        var records = [
            AirPrintAdvertisementPlan.TXTRecord(key: "txtvers", value: "1"),
            AirPrintAdvertisementPlan.TXTRecord(key: "qtotal", value: "1"),
            AirPrintAdvertisementPlan.TXTRecord(key: "rp", value: rpValue),
            AirPrintAdvertisementPlan.TXTRecord(key: "ty", value: printerInfo),
            AirPrintAdvertisementPlan.TXTRecord(key: "product", value: "(\(makeAndModel))"),
            AirPrintAdvertisementPlan.TXTRecord(key: "priority", value: "0"),
            AirPrintAdvertisementPlan.TXTRecord(key: "Color", value: colorValue),
            AirPrintAdvertisementPlan.TXTRecord(key: "Duplex", value: duplexValue),
            AirPrintAdvertisementPlan.TXTRecord(key: "Binary", value: "T"),
            AirPrintAdvertisementPlan.TXTRecord(key: "Transparent", value: "T"),
        ]

        if !documentFormats.isEmpty {
            records.append(.init(key: "pdl", value: documentFormats.joined(separator: ",")))
        }

        if let urfValue = deriveURFValue(from: attributes) {
            records.append(.init(key: "URF", value: urfValue))
        }

        return records
    }

    private func supportedDocumentFormats(from attributes: IPPPrinterAttributesSnapshot?) -> [String] {
        guard let attributes else {
            return []
        }

        let preferredFormats = [
            "application/pdf",
            "image/urf",
            "image/pwg-raster",
            "image/jpeg",
        ]
        let supportedFormats = Set(attributes.values(named: "document-format-supported"))
        return preferredFormats.filter { supportedFormats.contains($0) }
    }

    private func supportsDuplex(
        attributes: IPPPrinterAttributesSnapshot?,
        inspection: PrinterQueueInspection
    ) -> Bool {
        let sides = Set(attributes?.values(named: "sides-supported") ?? [])
        if sides.contains("two-sided-long-edge") || sides.contains("two-sided-short-edge") {
            return true
        }

        return inspection.options.contains { option in
            option.key == "Duplex" && option.values.contains(where: { $0.value.caseInsensitiveCompare("None") != .orderedSame })
        }
    }

    private func deriveURFValue(from attributes: IPPPrinterAttributesSnapshot?) -> String? {
        guard let attributes else {
            return nil
        }

        let supportedFormats = Set(attributes.values(named: "document-format-supported"))
        guard supportedFormats.contains("image/urf") else {
            return nil
        }

        let colorMode = (attributes.boolValue(named: "color-supported") ?? false) ? "SRGB24" : "W8"
        let resolutionValues = attributes.values(named: "printer-resolution-supported")
        let numericResolutions = resolutionValues.compactMap { value -> Int? in
            let digits = value.filter(\.isNumber)
            return Int(digits)
        }

        var components = [colorMode]
        if !numericResolutions.isEmpty {
            let renderedResolutions = numericResolutions
                .sorted()
                .map(String.init)
                .joined(separator: "-")
            components.append("RS\(renderedResolutions)")
        }

        return components.joined(separator: ",")
    }

    private func makeWarnings(
        inspection: PrinterQueueInspection,
        attributes: IPPPrinterAttributesSnapshot?,
        txtRecords: [AirPrintAdvertisementPlan.TXTRecord],
        exposureMode: BridgeExposureMode
    ) -> [String] {
        var warnings: [String] = []

        guard let attributes else {
            warnings.append("Unable to read IPP attributes with ipptool. TXT records are incomplete.")
            return warnings
        }

        if exposureMode == .directCUPS, attributes.boolValue(named: "printer-is-shared") == false {
            warnings.append("The selected CUPS queue is not shared yet. Direct CUPS exposure will not work until host sharing or proxying is enabled.")
        }

        let requiredFormats = Set(["application/pdf", "image/urf", "image/pwg-raster"])
        let supportedFormats = Set(attributes.values(named: "document-format-supported"))
        if !requiredFormats.isSubset(of: supportedFormats) {
            warnings.append("The queue does not expose the full PDF + URF + PWG raster format set expected for broad AirPrint compatibility.")
        }

        if !txtRecords.contains(where: { $0.key == "URF" }) {
            warnings.append("The queue supports AirPrint formats, but a URF capability string could not be derived yet.")
        }

        if exposureMode == .directCUPS, attributes.stringValue(named: "printer-uri-supported") == nil {
            warnings.append("The queue did not report printer-uri-supported in its IPP attributes.")
        }

        if inspection.summary.deviceURI == nil || inspection.summary.deviceURI?.isEmpty == true {
            warnings.append("The queue is missing a backing device URI.")
        }

        return warnings
    }

    public static func defaultHostName() -> String {
        preferredBonjourHostName(
            localHostName: SCDynamicStoreCopyLocalHostName(nil) as String?,
            hostCurrentName: Host.current().name,
            processHostName: ProcessInfo.processInfo.hostName
        )
    }

    static func preferredBonjourHostName(
        localHostName: String?,
        hostCurrentName: String?,
        processHostName: String?
    ) -> String {
        if let localHostName = normalizeBonjourHostName(localHostName, requireLocalIdentity: false) {
            return localHostName.hasSuffix(".local") ? localHostName : "\(localHostName).local"
        }

        if let hostCurrentName = normalizeBonjourHostName(hostCurrentName, requireLocalIdentity: true) {
            return hostCurrentName
        }

        if let processHostName = normalizeBonjourHostName(processHostName, requireLocalIdentity: true) {
            return processHostName
        }

        return "localhost.local"
    }

    private static func normalizeBonjourHostName(
        _ candidate: String?,
        requireLocalIdentity: Bool
    ) -> String? {
        guard let candidate else {
            return nil
        }

        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.hasSuffix(".local") {
            return trimmed
        }

        if !trimmed.contains(".") {
            return "\(trimmed).local"
        }

        return requireLocalIdentity ? nil : trimmed
    }
}
