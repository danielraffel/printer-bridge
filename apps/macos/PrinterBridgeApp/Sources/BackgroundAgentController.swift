import Darwin
import Foundation
import PrinterBridgeCore
import ServiceManagement

enum BackgroundAgentState: Equatable {
    case stopped
    case running
    case loaded
    case requiresApproval
    case failed(String)
}

struct BackgroundAgentController {
    private let runner: any CommandRunning
    private let fileManager: FileManager
    private let label: String
    private let plistName: String
    private let legacyLabel: String

    init(
        runner: any CommandRunning = ProcessCommandRunner(),
        fileManager: FileManager = .default,
        label: String = ProjectMetadata.backgroundAgentLabel,
        plistName: String = ProjectMetadata.backgroundAgentPlistName,
        legacyLabel: String = ProjectMetadata.legacyBackgroundDaemonLabel
    ) {
        self.runner = runner
        self.fileManager = fileManager
        self.label = label
        self.plistName = plistName
        self.legacyLabel = legacyLabel
    }

    func ensureInstalled(forceRestart: Bool) throws -> BackgroundAgentState {
        try validateBundledService()
        try cleanupLegacyLaunchAgent()

        let service = serviceReference()
        switch service.status {
        case .enabled:
            let currentState = launchdEnabledState()
            if forceRestart || currentState == .stopped {
                return try restartRegisteredAgent(service: service)
            }
            return currentState
        case .requiresApproval:
            return .requiresApproval
        case .notFound, .notRegistered:
            do {
                try service.register()
            } catch {
                let currentState = mapServiceStatus(service.status)
                switch currentState {
                case .running, .loaded, .requiresApproval:
                    return currentState
                case .stopped, .failed:
                    throw BackgroundAgentError.commandFailed("SMAppService.register()", error.localizedDescription)
                }
            }

            if forceRestart {
                return try restartRegisteredAgent(service: service)
            }

            return mapServiceStatus(service.status)
        @unknown default:
            return .failed("macOS returned an unknown background service state.")
        }
    }

    func disable() -> BackgroundAgentState {
        do {
            try cleanupLegacyLaunchAgent()
            let service = serviceReference()
            if service.status != .notRegistered {
                try service.unregister()
            }
        } catch {
            return .failed(error.localizedDescription)
        }

        _ = runner.run(executable: SystemTool.launchctl.path, arguments: ["bootout", serviceTarget])
        return .stopped
    }

    func status() -> BackgroundAgentState {
        do {
            try validateBundledService()
        } catch {
            return .failed(error.localizedDescription)
        }

        return mapServiceStatus(serviceReference().status)
    }

    private var serviceTarget: String {
        "\(domainTarget)/\(label)"
    }

    private var domainTarget: String {
        "gui/\(getuid())"
    }

    private var legacyLaunchAgentPlistURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(legacyLabel).plist", isDirectory: false)
    }

    private func serviceReference() -> SMAppService {
        SMAppService.agent(plistName: plistName)
    }

    private func launchdEnabledState() -> BackgroundAgentState {
        let result = runner.run(
            executable: SystemTool.launchctl.path,
            arguments: ["print", serviceTarget]
        )

        guard result.exitCode == 0 else {
            return .stopped
        }

        let output = result.combinedOutput
        if output.contains("state = running") {
            return .running
        }
        if output.contains("state = waiting") || output.contains("\"PID\" =") {
            return .loaded
        }

        return .loaded
    }

    private func restartRegisteredAgent(service: SMAppService) throws -> BackgroundAgentState {
        let kickstartResult = runner.run(
            executable: SystemTool.launchctl.path,
            arguments: ["kickstart", "-k", serviceTarget]
        )

        if kickstartResult.exitCode == 0 {
            return launchdEnabledState()
        }

        // SMAppService can retain an enabled registration across an app upgrade
        // even when launchd no longer has the corresponding job. Re-registering
        // refreshes the bundled plist and executable association.
        do {
            try service.unregister()
        } catch {
            if service.status != .notRegistered && service.status != .notFound {
                throw BackgroundAgentError.commandFailed("SMAppService.unregister()", error.localizedDescription)
            }
        }

        do {
            try service.register()
        } catch {
            let currentState = mapServiceStatus(service.status)
            if currentState != .running && currentState != .loaded && currentState != .requiresApproval {
                throw BackgroundAgentError.commandFailed("SMAppService.register()", error.localizedDescription)
            }
            return currentState
        }

        let registeredState = mapServiceStatus(service.status)
        guard registeredState == .running || registeredState == .loaded else {
            return registeredState
        }

        let registeredKickstartResult = runner.run(
            executable: SystemTool.launchctl.path,
            arguments: ["kickstart", "-k", serviceTarget]
        )
        guard registeredKickstartResult.exitCode == 0 else {
            return launchdEnabledState()
        }

        return launchdEnabledState()
    }

    private func mapServiceStatus(_ status: SMAppService.Status) -> BackgroundAgentState {
        switch status {
        case .notRegistered, .notFound:
            return .stopped
        case .enabled:
            return launchdEnabledState()
        case .requiresApproval:
            return .requiresApproval
        @unknown default:
            return .failed("macOS returned an unknown background service state.")
        }
    }

    private func validateBundledService(bundle: Bundle = .main) throws {
        let daemonURL = try bundledDaemonURL(bundle: bundle)
        let agentPlistURL = try bundledLaunchAgentPlistURL(bundle: bundle)

        guard fileManager.isExecutableFile(atPath: daemonURL.path) else {
            throw BackgroundAgentError.missingBundledDaemon(daemonURL.path)
        }

        guard fileManager.fileExists(atPath: agentPlistURL.path) else {
            throw BackgroundAgentError.missingBundledLaunchAgent(agentPlistURL.path)
        }
    }

    private func bundledDaemonURL(bundle: Bundle = .main) throws -> URL {
        guard let resourceURL = bundle.resourceURL else {
            throw BackgroundAgentError.missingResourceDirectory
        }

        return resourceURL.appendingPathComponent(ProjectMetadata.backgroundAgentExecutableName, isDirectory: false)
    }

    private func bundledLaunchAgentPlistURL(bundle: Bundle = .main) throws -> URL {
        let plistURL = bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent(plistName, isDirectory: false)

        return plistURL
    }

    private func cleanupLegacyLaunchAgent() throws {
        _ = runner.run(executable: SystemTool.launchctl.path, arguments: ["bootout", "\(domainTarget)/\(legacyLabel)"])
        _ = runner.run(executable: SystemTool.launchctl.path, arguments: ["disable", "\(domainTarget)/\(legacyLabel)"])

        if fileManager.fileExists(atPath: legacyLaunchAgentPlistURL.path) {
            try fileManager.removeItem(at: legacyLaunchAgentPlistURL)
        }
    }
}

enum BackgroundAgentError: LocalizedError {
    case missingResourceDirectory
    case missingBundledDaemon(String)
    case missingBundledLaunchAgent(String)
    case commandFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .missingResourceDirectory:
            return "The app bundle is missing its resources directory."
        case let .missingBundledDaemon(path):
            return "\(ProjectMetadata.appDisplayName) could not find its background service inside the app bundle at \(path)."
        case let .missingBundledLaunchAgent(path):
            return "The bundled background agent plist was not found at \(path)."
        case let .commandFailed(command, output):
            let normalizedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedOutput.isEmpty {
                return "The background service command failed: \(command)"
            }
            return "The background service command failed: \(command)\n\(normalizedOutput)"
        }
    }
}
