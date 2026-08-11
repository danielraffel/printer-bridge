import Foundation
import Network

public enum BridgeRuntimeError: LocalizedError {
    case unsupportedExposureMode(BridgeExposureMode)
    case missingAdvertisementPlan
    case failedToStartProxy(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedExposureMode(mode):
            return "PrinterBridge does not support `\(mode.rawValue)` yet."
        case .missingAdvertisementPlan:
            return "The bridge did not generate an AirPrint advertisement plan."
        case let .failedToStartProxy(reason):
            return "Failed to start the local AirPrint proxy: \(reason)"
        }
    }
}

public final class BridgeRuntimeSession {
    public let advertisementPlan: AirPrintAdvertisementPlan

    private let bonjourSession: BonjourAdvertisementSession
    private let proxySession: ProxyAirPrintServerSession?

    fileprivate init(
        advertisementPlan: AirPrintAdvertisementPlan,
        bonjourSession: BonjourAdvertisementSession,
        proxySession: ProxyAirPrintServerSession?
    ) {
        self.advertisementPlan = advertisementPlan
        self.bonjourSession = bonjourSession
        self.proxySession = proxySession
    }

    deinit {
        stop()
    }

    public var isRunning: Bool {
        bonjourSession.isRunning && (proxySession?.isRunning ?? true)
    }

    @discardableResult
    public func stop() -> Int32 {
        proxySession?.stop()
        return bonjourSession.stop()
    }
}

public struct BridgeRuntimeService {
    private let bonjourService: BonjourAdvertisementService
    private let proxyService: ProxyAirPrintServer

    public init(
        bonjourService: BonjourAdvertisementService = BonjourAdvertisementService(),
        proxyService: ProxyAirPrintServer = ProxyAirPrintServer()
    ) {
        self.bonjourService = bonjourService
        self.proxyService = proxyService
    }

    public func start(
        advertisementPlan: AirPrintAdvertisementPlan,
        outputHandler: (@Sendable (String) -> Void)? = nil
    ) throws -> BridgeRuntimeSession {
        switch advertisementPlan.exposureMode {
        case .directCUPS:
            let bonjourSession = try bonjourService.publish(advertisementPlan, outputHandler: outputHandler)
            return BridgeRuntimeSession(
                advertisementPlan: advertisementPlan,
                bonjourSession: bonjourSession,
                proxySession: nil
            )
        case .proxy:
            let proxySession = try proxyService.start(advertisementPlan: advertisementPlan, outputHandler: outputHandler)
            do {
                let bonjourSession = try bonjourService.publish(advertisementPlan, outputHandler: outputHandler)
                return BridgeRuntimeSession(
                    advertisementPlan: advertisementPlan,
                    bonjourSession: bonjourSession,
                    proxySession: proxySession
                )
            } catch {
                proxySession.stop()
                throw error
            }
        }
    }
}

public enum ProxyAirPrintError: LocalizedError {
    case invalidPort(Int)
    case failedToStart(String)
    case startupTimedOut(Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidPort(port):
            return "The AirPrint proxy port `\(port)` is invalid."
        case let .failedToStart(reason):
            return "The AirPrint proxy failed to start: \(reason)"
        case let .startupTimedOut(port):
            return "The AirPrint proxy did not become ready on port \(port) before the startup timeout."
        }
    }
}

public final class ProxyAirPrintServerSession {
    public let advertisementPlan: AirPrintAdvertisementPlan

    private let listener: NWListener
    private let state: ProxyAirPrintServerState

    fileprivate init(
        advertisementPlan: AirPrintAdvertisementPlan,
        listener: NWListener,
        state: ProxyAirPrintServerState
    ) {
        self.advertisementPlan = advertisementPlan
        self.listener = listener
        self.state = state
    }

    deinit {
        stop()
    }

    public var isRunning: Bool {
        state.isRunning
    }

    public func stop() {
        listener.cancel()
        state.markStopped()
    }
}

public struct ProxyAirPrintServer {
    private let inventoryService: PrinterInventoryService
    private let attributeService: IPPPrinterAttributeService
    private let jobQueueService: PrintJobQueueService
    private let submissionService: PrintJobSubmissionService

    public init(
        inventoryService: PrinterInventoryService = PrinterInventoryService(),
        attributeService: IPPPrinterAttributeService = IPPPrinterAttributeService(),
        jobQueueService: PrintJobQueueService = PrintJobQueueService(),
        submissionService: PrintJobSubmissionService = PrintJobSubmissionService()
    ) {
        self.inventoryService = inventoryService
        self.attributeService = attributeService
        self.jobQueueService = jobQueueService
        self.submissionService = submissionService
    }

    public func start(
        advertisementPlan: AirPrintAdvertisementPlan,
        startupTimeout: TimeInterval = 5,
        outputHandler: (@Sendable (String) -> Void)? = nil
    ) throws -> ProxyAirPrintServerSession {
        guard advertisementPlan.exposureMode == .proxy else {
            throw BridgeRuntimeError.unsupportedExposureMode(advertisementPlan.exposureMode)
        }

        guard let port = NWEndpoint.Port(rawValue: UInt16(advertisementPlan.port)) else {
            throw ProxyAirPrintError.invalidPort(advertisementPlan.port)
        }

        let queue = DispatchQueue(
            label: "com.danielraffel.printerbridge.proxy",
            qos: .userInitiated
        )
        let handler = ProxyAirPrintRequestHandler(
            advertisementPlan: advertisementPlan,
            inventoryService: inventoryService,
            attributeService: attributeService,
            jobQueueService: jobQueueService,
            submissionService: submissionService,
            outputHandler: outputHandler
        )
        let state = ProxyAirPrintServerState()
        let listener: NWListener

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            listener = try NWListener(using: parameters, on: port)
        } catch {
            throw ProxyAirPrintError.failedToStart(error.localizedDescription)
        }

        listener.stateUpdateHandler = { listenerState in
            switch listenerState {
            case .ready:
                state.markReady()
                outputHandler?("[proxy] Listening on port \(advertisementPlan.port)")
            case let .failed(error):
                state.markFailed(error.localizedDescription)
                outputHandler?("[proxy] Failed: \(error.localizedDescription)")
            case .cancelled:
                state.markStopped()
                outputHandler?("[proxy] Stopped")
            default:
                break
            }
        }

        listener.newConnectionHandler = { connection in
            outputHandler?("[proxy] Accepted connection")
            handler.handle(connection: connection, on: queue)
        }

        listener.start(queue: queue)

        switch state.waitUntilReady(timeout: startupTimeout) {
        case .ready:
            return ProxyAirPrintServerSession(
                advertisementPlan: advertisementPlan,
                listener: listener,
                state: state
            )
        case let .failed(reason):
            listener.cancel()
            throw ProxyAirPrintError.failedToStart(reason)
        case .timedOut:
            listener.cancel()
            throw ProxyAirPrintError.startupTimedOut(advertisementPlan.port)
        }
    }
}

public enum PrintJobSubmissionError: LocalizedError, Equatable {
    case emptyDocument
    case submitFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyDocument:
            return "The print job did not include document data."
        case let .submitFailed(reason):
            return "CUPS rejected the print job: \(reason)"
        }
    }
}

public struct PrintJobSubmissionResult: Equatable, Sendable {
    public let queueName: String
    public let jobIdentifier: String?
    public let jobNumber: Int?
    public let rawOutput: String

    public init(queueName: String, jobIdentifier: String?, jobNumber: Int?, rawOutput: String) {
        self.queueName = queueName
        self.jobIdentifier = jobIdentifier
        self.jobNumber = jobNumber
        self.rawOutput = rawOutput
    }
}

public struct PrintJobSubmissionService {
    private let runner: any CommandRunning
    private let fileManager: FileManager

    public init(
        runner: any CommandRunning = ProcessCommandRunner(),
        fileManager: FileManager = .default
    ) {
        self.runner = runner
        self.fileManager = fileManager
    }

    public func submit(
        documentData: Data,
        toQueueNamed queueName: String,
        jobName: String?,
        documentFormat: String?
    ) throws -> PrintJobSubmissionResult {
        guard !documentData.isEmpty else {
            throw PrintJobSubmissionError.emptyDocument
        }

        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(ProjectMetadata.productName, isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let fileExtension = fileExtension(for: documentFormat)
        let temporaryFileURL = temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        try documentData.write(to: temporaryFileURL, options: .atomic)
        defer {
            try? fileManager.removeItem(at: temporaryFileURL)
        }

        var arguments = ["-d", queueName]
        if let jobName, !jobName.isEmpty {
            arguments += ["-t", jobName]
        }
        arguments.append(temporaryFileURL.path)

        let result = runner.run(executable: SystemTool.lp.path, arguments: arguments)
        guard result.exitCode == 0 else {
            throw PrintJobSubmissionError.submitFailed(result.combinedOutput.isEmpty ? "unknown error" : result.combinedOutput)
        }

        let jobIdentifier = parseJobIdentifier(from: result.combinedOutput)
        let jobNumber = jobIdentifier
            .flatMap { $0.split(separator: "-").last }
            .flatMap { Int($0) }

        return PrintJobSubmissionResult(
            queueName: queueName,
            jobIdentifier: jobIdentifier,
            jobNumber: jobNumber,
            rawOutput: result.combinedOutput
        )
    }

    private func fileExtension(for documentFormat: String?) -> String {
        switch documentFormat?.lowercased() {
        case "application/pdf":
            return "pdf"
        case "image/jpeg":
            return "jpg"
        case "image/urf":
            return "urf"
        case "image/pwg-raster":
            return "pwg"
        default:
            return "bin"
        }
    }

    private func parseJobIdentifier(from output: String) -> String? {
        guard let prefixRange = output.range(of: "request id is ") else {
            return nil
        }

        let suffix = output[prefixRange.upperBound...]
        return suffix.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }
}

private final class ProxyAirPrintServerState: @unchecked Sendable {
    enum ReadyResult {
        case ready
        case failed(String)
        case timedOut
    }

    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var ready = false
    private var failureReason: String?
    private(set) var isRunning = false

    func markReady() {
        lock.withLock {
            guard !ready && failureReason == nil else {
                return
            }
            ready = true
            isRunning = true
            semaphore.signal()
        }
    }

    func markFailed(_ reason: String) {
        lock.withLock {
            guard !ready && failureReason == nil else {
                return
            }
            failureReason = reason
            semaphore.signal()
        }
    }

    func markStopped() {
        lock.withLock {
            isRunning = false
        }
    }

    func waitUntilReady(timeout: TimeInterval) -> ReadyResult {
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            return .timedOut
        }

        return lock.withLock {
            if ready {
                return .ready
            }

            return .failed(failureReason ?? "unknown error")
        }
    }
}

private final class ProxyAirPrintRequestHandler: @unchecked Sendable {
    private struct CapabilitySnapshot {
        let attributes: IPPPrinterAttributesSnapshot?
        let inspection: PrinterQueueInspection?
    }

    private let advertisementPlan: AirPrintAdvertisementPlan
    private let inventoryService: PrinterInventoryService
    private let attributeService: IPPPrinterAttributeService
    private let jobQueueService: PrintJobQueueService
    private let submissionService: PrintJobSubmissionService
    private let outputHandler: (@Sendable (String) -> Void)?
    private let capabilityLock = NSLock()
    private var cachedCapabilities: CapabilitySnapshot?

    init(
        advertisementPlan: AirPrintAdvertisementPlan,
        inventoryService: PrinterInventoryService,
        attributeService: IPPPrinterAttributeService,
        jobQueueService: PrintJobQueueService,
        submissionService: PrintJobSubmissionService,
        outputHandler: (@Sendable (String) -> Void)?
    ) {
        self.advertisementPlan = advertisementPlan
        self.inventoryService = inventoryService
        self.attributeService = attributeService
        self.jobQueueService = jobQueueService
        self.submissionService = submissionService
        self.outputHandler = outputHandler
        if advertisementPlan.prefetchedAttributes != nil || advertisementPlan.prefetchedInspection != nil {
            cachedCapabilities = CapabilitySnapshot(
                attributes: advertisementPlan.prefetchedAttributes,
                inspection: advertisementPlan.prefetchedInspection
            )
        }
    }

    func handle(connection: NWConnection, on queue: DispatchQueue) {
        let assembler = HTTPRequestAssembler()
        connection.stateUpdateHandler = { [outputHandler] state in
            if case let .failed(error) = state {
                outputHandler?("[proxy] Connection failed: \(error.localizedDescription)")
            }
        }
        connection.start(queue: queue)
        receiveNextChunk(on: connection, assembler: assembler, queue: queue)
    }

    private func receiveNextChunk(
        on connection: NWConnection,
        assembler: HTTPRequestAssembler,
        queue: DispatchQueue
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                self.outputHandler?("[proxy] Receive error: \(error.localizedDescription)")
                connection.cancel()
                return
            }

            if let data, !data.isEmpty {
                assembler.append(data)
            }

            if assembler.shouldSendContinue {
                assembler.markContinueSent()
                self.sendRawHTTPResponse(
                    statusCode: 100,
                    reasonPhrase: "Continue",
                    body: Data(),
                    isFinal: false,
                    on: connection
                ) {
                    if let request = assembler.takeRequest() {
                        let response = self.handle(request: request)
                        self.send(response: response, on: connection, queue: queue)
                    } else {
                        self.receiveNextChunk(on: connection, assembler: assembler, queue: queue)
                    }
                }
                return
            }

            if let request = assembler.takeRequest() {
                let response = self.handle(request: request)
                self.send(response: response, on: connection, queue: queue)
                return
            }

            if isComplete {
                self.outputHandler?("[proxy] Connection closed before a full request arrived.")
                connection.cancel()
                return
            }

            self.receiveNextChunk(on: connection, assembler: assembler, queue: queue)
        }
    }

    private func handle(request: HTTPInboundRequest) -> HTTPOutboundResponse {
        let requestPath = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        guard request.method == "POST", requestPath == advertisementPlan.resourcePath else {
            return .text(statusCode: 404, reasonPhrase: "Not Found", body: "PrinterBridge proxy endpoint not found.")
        }

        guard request.contentType?.localizedCaseInsensitiveContains("application/ipp") == true else {
            return .text(statusCode: 415, reasonPhrase: "Unsupported Media Type", body: "Expected application/ipp.")
        }

        let ippRequest: IPPRequest
        do {
            ippRequest = try IPPRequestParser.parse(request.body)
        } catch {
            outputHandler?("[proxy] Failed to parse IPP request: \(error.localizedDescription)")
            let response = makeSimpleResponse(
                requestID: 1,
                statusCode: .clientErrorBadRequest
            )
            return .ipp(response)
        }

        let response = handle(ippRequest: ippRequest)
        return .ipp(response)
    }

    private func handle(ippRequest: IPPRequest) -> IPPResponse {
        let queueName = advertisementPlan.backingQueueName

        switch ippRequest.operationID {
        case .getPrinterAttributes:
            outputHandler?("[proxy] Get-Printer-Attributes for \(queueName)")
            let capabilities = capabilities(forQueueNamed: queueName)
            return buildPrinterAttributesResponse(
                request: ippRequest,
                inspection: capabilities.inspection,
                attributes: capabilities.attributes
            )
        case .validateJob:
            outputHandler?("[proxy] Validate-Job for \(queueName)")
            return makeSimpleResponse(
                requestID: ippRequest.requestID,
                statusCode: .successfulOK
            )
        case .printJob:
            let jobName = ippRequest.firstStringValue(named: "job-name")
            let documentFormat = ippRequest.firstStringValue(named: "document-format")
            outputHandler?("[proxy] Print-Job \(jobName ?? "(untitled)") format=\(documentFormat ?? "unknown") size=\(ippRequest.documentData.count)")

            do {
                let submission = try submissionService.submit(
                    documentData: ippRequest.documentData,
                    toQueueNamed: queueName,
                    jobName: jobName,
                    documentFormat: documentFormat
                )
                return buildPrintJobResponse(
                    request: ippRequest,
                    queueName: queueName,
                    submission: submission,
                    jobName: jobName,
                    owner: ippRequest.firstStringValue(named: "requesting-user-name")
                )
            } catch {
                outputHandler?("[proxy] Print-Job failed: \(error.localizedDescription)")
                return makeSimpleResponse(
                    requestID: ippRequest.requestID,
                    statusCode: .serverErrorInternalError,
                    message: error.localizedDescription
                )
            }
        case .getJobAttributes:
            return buildGetJobAttributesResponse(request: ippRequest, queueName: queueName)
        case .getJobs:
            return buildGetJobsResponse(request: ippRequest, queueName: queueName)
        case .unsupported:
            outputHandler?("[proxy] Unsupported IPP operation: \(ippRequest.rawOperationID)")
            return makeSimpleResponse(
                requestID: ippRequest.requestID,
                statusCode: .serverErrorOperationNotSupported
            )
        }
    }

    private func capabilities(forQueueNamed queueName: String) -> CapabilitySnapshot {
        capabilityLock.withLock {
            if let cachedCapabilities {
                return cachedCapabilities
            }

            let snapshot = CapabilitySnapshot(
                attributes: attributeService.fetchAttributes(forQueueNamed: queueName),
                inspection: inventoryService.inspectQueue(named: queueName)
            )
            cachedCapabilities = snapshot
            return snapshot
        }
    }

    private func buildPrinterAttributesResponse(
        request: IPPRequest,
        inspection: PrinterQueueInspection?,
        attributes: IPPPrinterAttributesSnapshot?
    ) -> IPPResponse {
        let printerInfo = attributes?.stringValue(named: "printer-info")
            ?? inspection?.detail.description
            ?? advertisementPlan.serviceName
        let printerModel = attributes?.stringValue(named: "printer-make-and-model")
            ?? inspection?.detail.description
            ?? advertisementPlan.serviceName
        let documentFormats = preferredDocumentFormats(from: attributes)
        let supportsColor = attributes?.boolValue(named: "color-supported") ?? false
        let activeJobs = attributes?.intValue(named: "queued-job-count") ?? 0
        let state = printerStateValue(from: inspection?.summary.status)

        let groups = [
            makeOperationAttributesGroup(requestID: request.requestID),
            IPPResponseAttributeGroup(
                tag: .printerAttributes,
                attributes: [
                    .init(name: "printer-uri-supported", values: [.uri(advertisementPlan.printerURI)]),
                    .init(name: "uri-authentication-supported", values: [.keyword("none")]),
                    .init(name: "uri-security-supported", values: [.keyword("none")]),
                    .init(name: "printer-name", values: [.name(advertisementPlan.serviceName)]),
                    .init(name: "printer-info", values: [.text(printerInfo)]),
                    .init(name: "printer-make-and-model", values: [.text(printerModel)]),
                    .init(name: "printer-is-accepting-jobs", values: [.boolean(true)]),
                    .init(name: "printer-is-shared", values: [.boolean(true)]),
                    .init(name: "printer-state", values: [.enumeration(state)]),
                    .init(name: "printer-state-reasons", values: [.keyword("none")]),
                    .init(name: "queued-job-count", values: [.integer(activeJobs)]),
                    .init(name: "operations-supported", values: [
                        .enumeration(2),
                        .enumeration(4),
                        .enumeration(9),
                        .enumeration(10),
                        .enumeration(11),
                    ]),
                    .init(name: "charset-configured", values: [.charset("utf-8")]),
                    .init(name: "charset-supported", values: [.charset("utf-8")]),
                    .init(name: "generated-natural-language-supported", values: [.naturalLanguage("en")]),
                    .init(name: "natural-language-configured", values: [.naturalLanguage("en")]),
                    .init(name: "pdl-override-supported", values: [.keyword("not-attempted")]),
                    .init(name: "document-format-default", values: [.mimeType(documentFormats.first ?? "application/pdf")]),
                    .init(name: "document-format-supported", values: documentFormats.map(IPPResponseValue.mimeType)),
                    .init(name: "color-supported", values: [.boolean(supportsColor)]),
                ] + sidesSupportedAttributes(from: attributes)
            ),
        ]

        return IPPResponse(
            versionMajor: request.versionMajor,
            versionMinor: request.versionMinor,
            statusCode: .successfulOK,
            requestID: request.requestID,
            groups: groups
        )
    }

    private func buildPrintJobResponse(
        request: IPPRequest,
        queueName: String,
        submission: PrintJobSubmissionResult,
        jobName: String?,
        owner: String?
    ) -> IPPResponse {
        let jobNumber = submission.jobNumber ?? 0
        let jobURI = "ipp://\(advertisementPlan.hostName):\(advertisementPlan.port)/jobs/\(jobNumber)"

        return IPPResponse(
            versionMajor: request.versionMajor,
            versionMinor: request.versionMinor,
            statusCode: .successfulOK,
            requestID: request.requestID,
            groups: [
                makeOperationAttributesGroup(requestID: request.requestID),
                IPPResponseAttributeGroup(
                    tag: .jobAttributes,
                    attributes: [
                        .init(name: "job-uri", values: [.uri(jobURI)]),
                        .init(name: "job-id", values: [.integer(jobNumber)]),
                        .init(name: "job-state", values: [.enumeration(3)]),
                        .init(name: "job-state-reasons", values: [.keyword("none")]),
                        .init(name: "job-printer-uri", values: [.uri(advertisementPlan.printerURI)]),
                        .init(name: "job-name", values: [.name(jobName ?? submission.jobIdentifier ?? queueName)]),
                        .init(name: "job-originating-user-name", values: [.name(owner ?? "mobile")]),
                    ]
                ),
            ]
        )
    }

    private func buildGetJobAttributesResponse(request: IPPRequest, queueName: String) -> IPPResponse {
        let snapshot = jobQueueService.snapshot(forQueueNamed: queueName)
        let requestedJobNumber = request.firstIntegerValue(named: "job-id")
            ?? parseJobNumber(from: request.firstStringValue(named: "job-uri"))

        guard
            let requestedJobNumber,
            let job = (snapshot.activeJobs + snapshot.completedJobs).first(where: { $0.jobNumber == requestedJobNumber })
        else {
            return makeSimpleResponse(
                requestID: request.requestID,
                statusCode: .clientErrorNotFound,
                message: "Job not found."
            )
        }

        return IPPResponse(
            versionMajor: request.versionMajor,
            versionMinor: request.versionMinor,
            statusCode: .successfulOK,
            requestID: request.requestID,
            groups: [
                makeOperationAttributesGroup(requestID: request.requestID),
                makeJobAttributesGroup(job),
            ]
        )
    }

    private func buildGetJobsResponse(request: IPPRequest, queueName: String) -> IPPResponse {
        let snapshot = jobQueueService.snapshot(forQueueNamed: queueName)
        let jobs = Array((snapshot.activeJobs + snapshot.completedJobs).prefix(20))

        var groups = [makeOperationAttributesGroup(requestID: request.requestID)]
        groups.append(contentsOf: jobs.map(makeJobAttributesGroup(_:)))

        return IPPResponse(
            versionMajor: request.versionMajor,
            versionMinor: request.versionMinor,
            statusCode: .successfulOK,
            requestID: request.requestID,
            groups: groups
        )
    }

    private func makeSimpleResponse(
        requestID: UInt32,
        statusCode: IPPStatusCode,
        message: String? = nil
    ) -> IPPResponse {
        var attributes = makeOperationAttributesGroup(requestID: requestID).attributes
        if let message, !message.isEmpty {
            attributes.append(.init(name: "status-message", values: [.text(message)]))
        }

        return IPPResponse(
            versionMajor: 1,
            versionMinor: 1,
            statusCode: statusCode,
            requestID: requestID,
            groups: [IPPResponseAttributeGroup(tag: .operationAttributes, attributes: attributes)]
        )
    }

    private func makeOperationAttributesGroup(requestID: UInt32) -> IPPResponseAttributeGroup {
        IPPResponseAttributeGroup(
            tag: .operationAttributes,
            attributes: [
                .init(name: "attributes-charset", values: [.charset("utf-8")]),
                .init(name: "attributes-natural-language", values: [.naturalLanguage("en")]),
            ]
        )
    }

    private func makeJobAttributesGroup(_ job: PrintJob) -> IPPResponseAttributeGroup {
        let jobNumber = job.jobNumber ?? 0
        let jobURI = "ipp://\(advertisementPlan.hostName):\(advertisementPlan.port)/jobs/\(jobNumber)"
        let jobState = job.state == .active ? 5 : 9
        let jobStateReason = job.state == .active ? "job-printing" : "job-completed-successfully"

        return IPPResponseAttributeGroup(
            tag: .jobAttributes,
            attributes: [
                .init(name: "job-uri", values: [.uri(jobURI)]),
                .init(name: "job-id", values: [.integer(jobNumber)]),
                .init(name: "job-printer-uri", values: [.uri(advertisementPlan.printerURI)]),
                .init(name: "job-name", values: [.name(job.id)]),
                .init(name: "job-originating-user-name", values: [.name(job.owner)]),
                .init(name: "job-state", values: [.enumeration(jobState)]),
                .init(name: "job-state-reasons", values: [.keyword(jobStateReason)]),
            ]
        )
    }

    private func preferredDocumentFormats(from attributes: IPPPrinterAttributesSnapshot?) -> [String] {
        guard let attributes else {
            return ["application/pdf", "image/urf", "image/pwg-raster"]
        }

        let preferredFormats = [
            "application/pdf",
            "image/urf",
            "image/pwg-raster",
            "image/jpeg",
        ]
        let supportedFormats = Set(attributes.values(named: "document-format-supported"))
        let resolved = preferredFormats.filter { supportedFormats.contains($0) }
        return resolved.isEmpty ? preferredFormats : resolved
    }

    private func sidesSupportedAttributes(from attributes: IPPPrinterAttributesSnapshot?) -> [IPPResponseAttribute] {
        let sides = attributes?.values(named: "sides-supported") ?? ["one-sided"]
        return [.init(name: "sides-supported", values: sides.map(IPPResponseValue.keyword))]
    }

    private func printerStateValue(from status: String?) -> Int {
        switch status?.lowercased() {
        case "printing":
            return 4
        case "disabled", "stopped", "offline":
            return 5
        default:
            return 3
        }
    }

    private func parseJobNumber(from jobURI: String?) -> Int? {
        guard let jobURI else {
            return nil
        }

        return jobURI
            .split(separator: "/")
            .last
            .flatMap { Int($0) }
    }

    private func send(
        response: HTTPOutboundResponse,
        on connection: NWConnection,
        queue: DispatchQueue
    ) {
        sendRawHTTPResponse(
            statusCode: response.statusCode,
            reasonPhrase: response.reasonPhrase,
            headers: response.headers,
            body: response.body,
            on: connection
        ) {
            // `contentProcessed` means Network.framework accepted the bytes; it does
            // not mean the peer has consumed them. Cancelling immediately can turn a
            // graceful HTTP close into a TCP reset and intermittently discard the IPP
            // response before AirPrint reads it.
            queue.asyncAfter(deadline: .now() + 1) {
                connection.cancel()
            }
        }
    }

    private func sendRawHTTPResponse(
        statusCode: Int,
        reasonPhrase: String,
        headers: [String: String] = [:],
        body: Data,
        isFinal: Bool = true,
        on connection: NWConnection,
        completion: @escaping @Sendable () -> Void
    ) {
        var headerLines = ["HTTP/1.1 \(statusCode) \(reasonPhrase)"]
        if isFinal {
            headerLines.append("Connection: close")
        }
        let hasContentLength = headers.keys.contains {
            $0.caseInsensitiveCompare("Content-Length") == .orderedSame
        }
        if !body.isEmpty && !hasContentLength {
            headerLines.append("Content-Length: \(body.count)")
        }
        for key in headers.keys.sorted() {
            if let value = headers[key] {
                headerLines.append("\(key): \(value)")
            }
        }
        headerLines.append("")
        headerLines.append("")

        var responseData = Data(headerLines.joined(separator: "\r\n").utf8)
        responseData.append(body)

        let responseByteCount = responseData.count
        connection.send(
            content: responseData,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { [outputHandler] error in
                if let error {
                    outputHandler?("[proxy] Failed to send HTTP \(statusCode): \(error.localizedDescription)")
                } else {
                    outputHandler?("[proxy] Sent HTTP \(statusCode) response (\(responseByteCount) bytes).")
                }
                completion()
            }
        )
    }
}

struct HTTPInboundRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    var contentType: String? {
        headers["content-type"]
    }
}

private struct HTTPOutboundResponse {
    let statusCode: Int
    let reasonPhrase: String
    let headers: [String: String]
    let body: Data

    static func text(statusCode: Int, reasonPhrase: String, body: String) -> HTTPOutboundResponse {
        HTTPOutboundResponse(
            statusCode: statusCode,
            reasonPhrase: reasonPhrase,
            headers: [
                "Content-Length": String(body.utf8.count),
                "Content-Type": "text/plain; charset=utf-8",
            ],
            body: Data(body.utf8)
        )
    }

    static func ipp(_ response: IPPResponse) -> HTTPOutboundResponse {
        let body = response.encoded()
        return HTTPOutboundResponse(
            statusCode: 200,
            reasonPhrase: "OK",
            headers: [
                "Content-Length": String(body.count),
                "Content-Type": "application/ipp",
            ],
            body: body
        )
    }
}

final class HTTPRequestAssembler: @unchecked Sendable {
    private var buffer = Data()
    private var header: HTTPParsedHeader?
    private var sentContinue = false

    func append(_ data: Data) {
        buffer.append(data)
    }

    var shouldSendContinue: Bool {
        guard let header = parsedHeaderIfNeeded() else {
            return false
        }

        return header.expectsContinue && !sentContinue
    }

    func markContinueSent() {
        sentContinue = true
    }

    func takeRequest() -> HTTPInboundRequest? {
        guard let header = parsedHeaderIfNeeded() else {
            return nil
        }

        if header.usesChunkedTransferEncoding {
            let encodedBody = buffer.subdata(in: header.headerLength..<buffer.count)
            guard let body = Self.decodeChunkedBody(encodedBody) else {
                return nil
            }

            return HTTPInboundRequest(
                method: header.method,
                path: header.path,
                headers: header.headers,
                body: body
            )
        }

        let totalLength = header.headerLength + header.contentLength
        guard buffer.count >= totalLength else {
            return nil
        }

        let body = buffer.subdata(in: header.headerLength..<totalLength)
        return HTTPInboundRequest(
            method: header.method,
            path: header.path,
            headers: header.headers,
            body: body
        )
    }

    private func parsedHeaderIfNeeded() -> HTTPParsedHeader? {
        if let header {
            return header
        }

        guard let parsed = HTTPParsedHeader.parse(from: buffer) else {
            return nil
        }

        header = parsed
        return parsed
    }

    private static func decodeChunkedBody(_ data: Data) -> Data? {
        let lineEnding = Data("\r\n".utf8)
        let trailerEnding = Data("\r\n\r\n".utf8)
        var cursor = 0
        var decoded = Data()

        while cursor < data.count {
            guard let sizeLineRange = data.range(of: lineEnding, in: cursor..<data.count),
                  let sizeLine = String(
                      data: data.subdata(in: cursor..<sizeLineRange.lowerBound),
                      encoding: .ascii
                  ) else {
                return nil
            }

            let sizeToken = sizeLine.split(separator: ";", maxSplits: 1)[0]
                .trimmingCharacters(in: .whitespaces)
            guard let chunkSize = Int(sizeToken, radix: 16), chunkSize >= 0 else {
                return nil
            }
            cursor = sizeLineRange.upperBound

            if chunkSize == 0 {
                guard data.count >= cursor + lineEnding.count else {
                    return nil
                }
                if data[cursor] == 0x0D, data[cursor + 1] == 0x0A {
                    return decoded
                }
                guard data.range(of: trailerEnding, in: cursor..<data.count) != nil else {
                    return nil
                }
                return decoded
            }

            guard chunkSize <= data.count - cursor,
                  data.count - cursor - chunkSize >= lineEnding.count else {
                return nil
            }
            let chunkEnd = cursor + chunkSize
            guard data[chunkEnd] == 0x0D, data[chunkEnd + 1] == 0x0A else {
                return nil
            }
            decoded.append(data.subdata(in: cursor..<chunkEnd))
            cursor = chunkEnd + lineEnding.count
        }

        return nil
    }
}

struct HTTPParsedHeader {
    let method: String
    let path: String
    let headers: [String: String]
    let headerLength: Int
    let contentLength: Int
    let expectsContinue: Bool
    let usesChunkedTransferEncoding: Bool

    static func parse(from data: Data) -> HTTPParsedHeader? {
        let marker = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: marker) else {
            return nil
        }

        let headerData = data.subdata(in: 0..<range.upperBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let rawLines = headerString.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard let requestLine = rawLines.first else {
            return nil
        }

        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else {
            return nil
        }

        var headers: [String: String] = [:]
        for line in rawLines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        let expectsContinue = headers["expect"]?.localizedCaseInsensitiveContains("100-continue") == true
        let usesChunkedTransferEncoding = headers["transfer-encoding"]?
            .localizedCaseInsensitiveContains("chunked") == true

        return HTTPParsedHeader(
            method: String(requestParts[0]),
            path: String(requestParts[1]),
            headers: headers,
            headerLength: range.upperBound,
            contentLength: contentLength,
            expectsContinue: expectsContinue,
            usesChunkedTransferEncoding: usesChunkedTransferEncoding
        )
    }
}

public enum IPPOperationID: Sendable, Equatable {
    case printJob
    case validateJob
    case getJobAttributes
    case getJobs
    case getPrinterAttributes
    case unsupported

    fileprivate init(rawValue: UInt16) {
        switch rawValue {
        case 0x0002:
            self = .printJob
        case 0x0004:
            self = .validateJob
        case 0x0009:
            self = .getJobAttributes
        case 0x000A:
            self = .getJobs
        case 0x000B:
            self = .getPrinterAttributes
        default:
            self = .unsupported
        }
    }
}

public enum IPPStatusCode: UInt16, Sendable {
    case successfulOK = 0x0000
    case clientErrorBadRequest = 0x0400
    case clientErrorNotFound = 0x0406
    case serverErrorInternalError = 0x0500
    case serverErrorOperationNotSupported = 0x0501
}

public enum IPPAttributeGroupTag: UInt8, Sendable {
    case operationAttributes = 0x01
    case jobAttributes = 0x02
    case endOfAttributes = 0x03
    case printerAttributes = 0x04
    case unsupportedAttributes = 0x05
}

public struct IPPRequestAttribute: Equatable, Sendable {
    public let name: String
    public let valueTag: UInt8
    public let valueData: Data

    public var stringValue: String? {
        String(data: valueData, encoding: .utf8)
    }

    public var integerValue: Int? {
        guard valueData.count == 4 else {
            return nil
        }
        return Int(valueData.readUInt32BE(at: 0) ?? 0)
    }
}

public struct IPPRequestAttributeGroup: Equatable, Sendable {
    public let tag: IPPAttributeGroupTag
    public let attributes: [IPPRequestAttribute]
}

public struct IPPRequest: Equatable, Sendable {
    public let versionMajor: UInt8
    public let versionMinor: UInt8
    public let operationID: IPPOperationID
    public let rawOperationID: UInt16
    public let requestID: UInt32
    public let groups: [IPPRequestAttributeGroup]
    public let documentData: Data

    public func firstStringValue(named name: String) -> String? {
        groups
            .flatMap(\.attributes)
            .first(where: { $0.name == name })?
            .stringValue
    }

    public func firstIntegerValue(named name: String) -> Int? {
        groups
            .flatMap(\.attributes)
            .first(where: { $0.name == name })?
            .integerValue
    }
}

public enum IPPRequestParserError: LocalizedError, Equatable {
    case messageTooShort
    case malformedAttribute
    case missingAttributeGroup

    public var errorDescription: String? {
        switch self {
        case .messageTooShort:
            return "IPP message is too short."
        case .malformedAttribute:
            return "IPP attribute encoding is malformed."
        case .missingAttributeGroup:
            return "IPP request does not contain an attribute group."
        }
    }
}

public enum IPPResponseValue: Sendable, Equatable {
    case charset(String)
    case naturalLanguage(String)
    case uri(String)
    case name(String)
    case text(String)
    case keyword(String)
    case mimeType(String)
    case boolean(Bool)
    case integer(Int)
    case enumeration(Int)

    fileprivate var valueTag: UInt8 {
        switch self {
        case .integer:
            return 0x21
        case .boolean:
            return 0x22
        case .enumeration:
            return 0x23
        case .text:
            return 0x41
        case .name:
            return 0x42
        case .keyword:
            return 0x44
        case .uri:
            return 0x45
        case .charset:
            return 0x47
        case .naturalLanguage:
            return 0x48
        case .mimeType:
            return 0x49
        }
    }

    fileprivate var encodedData: Data {
        switch self {
        case let .charset(value),
             let .naturalLanguage(value),
             let .uri(value),
             let .name(value),
             let .text(value),
             let .keyword(value),
             let .mimeType(value):
            return Data(value.utf8)
        case let .boolean(value):
            return Data([value ? 1 : 0])
        case let .integer(value),
             let .enumeration(value):
            var data = Data()
            data.appendUInt32BE(UInt32(max(0, value)))
            return data
        }
    }
}

public struct IPPResponseAttribute: Sendable, Equatable {
    public let name: String
    public let values: [IPPResponseValue]

    public init(name: String, values: [IPPResponseValue]) {
        self.name = name
        self.values = values
    }
}

public struct IPPResponseAttributeGroup: Sendable, Equatable {
    public let tag: IPPAttributeGroupTag
    public let attributes: [IPPResponseAttribute]

    public init(tag: IPPAttributeGroupTag, attributes: [IPPResponseAttribute]) {
        self.tag = tag
        self.attributes = attributes
    }
}

public struct IPPResponse: Sendable, Equatable {
    public let versionMajor: UInt8
    public let versionMinor: UInt8
    public let statusCode: IPPStatusCode
    public let requestID: UInt32
    public let groups: [IPPResponseAttributeGroup]

    public init(
        versionMajor: UInt8,
        versionMinor: UInt8,
        statusCode: IPPStatusCode,
        requestID: UInt32,
        groups: [IPPResponseAttributeGroup]
    ) {
        self.versionMajor = versionMajor
        self.versionMinor = versionMinor
        self.statusCode = statusCode
        self.requestID = requestID
        self.groups = groups
    }

    public func encoded() -> Data {
        var data = Data([versionMajor, versionMinor])
        data.appendUInt16BE(statusCode.rawValue)
        data.appendUInt32BE(requestID)

        for group in groups {
            data.append(group.tag.rawValue)
            for attribute in group.attributes where !attribute.values.isEmpty {
                for (index, value) in attribute.values.enumerated() {
                    data.append(value.valueTag)
                    if index == 0 {
                        data.appendStringWithUInt16Length(attribute.name)
                    } else {
                        data.appendUInt16BE(0)
                    }
                    let encodedValue = value.encodedData
                    data.appendUInt16BE(UInt16(encodedValue.count))
                    data.append(encodedValue)
                }
            }
        }

        data.append(IPPAttributeGroupTag.endOfAttributes.rawValue)
        return data
    }
}

public enum IPPRequestParser {
    public static func parse(_ data: Data) throws -> IPPRequest {
        guard data.count >= 8 else {
            throw IPPRequestParserError.messageTooShort
        }

        let versionMajor = data[0]
        let versionMinor = data[1]
        guard
            let rawOperationID = data.readUInt16BE(at: 2),
            let requestID = data.readUInt32BE(at: 4)
        else {
            throw IPPRequestParserError.messageTooShort
        }

        var cursor = 8
        var groups: [IPPRequestAttributeGroup] = []
        var currentGroupTag: IPPAttributeGroupTag?
        var currentAttributes: [IPPRequestAttribute] = []
        var currentAttributeName: String?

        while cursor < data.count {
            let tag = data[cursor]
            cursor += 1

            if let groupTag = IPPAttributeGroupTag(rawValue: tag) {
                if groupTag == .endOfAttributes {
                    if let currentGroupTag {
                        groups.append(.init(tag: currentGroupTag, attributes: currentAttributes))
                    }
                    let documentData = cursor < data.count ? data.subdata(in: cursor..<data.count) : Data()
                    guard !groups.isEmpty else {
                        throw IPPRequestParserError.missingAttributeGroup
                    }
                    return IPPRequest(
                        versionMajor: versionMajor,
                        versionMinor: versionMinor,
                        operationID: IPPOperationID(rawValue: rawOperationID),
                        rawOperationID: rawOperationID,
                        requestID: requestID,
                        groups: groups,
                        documentData: documentData
                    )
                }

                if let currentGroupTag {
                    groups.append(.init(tag: currentGroupTag, attributes: currentAttributes))
                }

                currentGroupTag = groupTag
                currentAttributes = []
                currentAttributeName = nil
                continue
            }

            guard
                let nameLength = data.readUInt16BE(at: cursor)
            else {
                throw IPPRequestParserError.malformedAttribute
            }
            cursor += 2

            let name: String
            if nameLength == 0 {
                guard let currentAttributeName else {
                    throw IPPRequestParserError.malformedAttribute
                }
                name = currentAttributeName
            } else {
                let endIndex = cursor + Int(nameLength)
                guard endIndex <= data.count else {
                    throw IPPRequestParserError.malformedAttribute
                }
                name = String(data: data.subdata(in: cursor..<endIndex), encoding: .utf8) ?? ""
                cursor = endIndex
                currentAttributeName = name
            }

            guard let valueLength = data.readUInt16BE(at: cursor) else {
                throw IPPRequestParserError.malformedAttribute
            }
            cursor += 2

            let endIndex = cursor + Int(valueLength)
            guard endIndex <= data.count else {
                throw IPPRequestParserError.malformedAttribute
            }

            let valueData = data.subdata(in: cursor..<endIndex)
            cursor = endIndex

            currentAttributes.append(.init(name: name, valueTag: tag, valueData: valueData))
        }

        throw IPPRequestParserError.malformedAttribute
    }
}

private extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendStringWithUInt16Length(_ value: String) {
        let encoded = Data(value.utf8)
        appendUInt16BE(UInt16(encoded.count))
        append(encoded)
    }

    func readUInt16BE(at offset: Int) -> UInt16? {
        guard count >= offset + 2 else {
            return nil
        }

        return (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func readUInt32BE(at offset: Int) -> UInt32? {
        guard count >= offset + 4 else {
            return nil
        }

        return (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
