import Darwin
import Foundation
import PrinterBridgeCore

enum BackgroundAgentState: Equatable {
    case stopped
    case running
    case loaded
    case failed(String)
}

struct BackgroundAgentController {
    private let runner: any CommandRunning
    private let fileManager: FileManager
    private let label: String

    init(
        runner: any CommandRunning = ProcessCommandRunner(),
        fileManager: FileManager = .default,
        label: String = ProjectMetadata.backgroundDaemonLabel
    ) {
        self.runner = runner
        self.fileManager = fileManager
        self.label = label
    }

    func ensureInstalled(configURL: URL, forceRestart: Bool) throws -> BackgroundAgentState {
        let plistURL = try writeLaunchAgentPlist(configURL: configURL)

        if forceRestart {
            _ = runner.run(executable: SystemTool.launchctl.path, arguments: ["bootout", domainTarget, plistURL.path])
        } else {
            let current = status()
            if current == .running || current == .loaded {
                return current
            }
        }

        _ = runner.run(executable: SystemTool.launchctl.path, arguments: ["enable", serviceTarget])

        let bootstrapResult = runner.run(
            executable: SystemTool.launchctl.path,
            arguments: ["bootstrap", domainTarget, plistURL.path]
        )
        if bootstrapResult.exitCode != 0 {
            let output = bootstrapResult.combinedOutput.lowercased()
            let alreadyLoaded = output.contains("already bootstrapped") || output.contains("service already loaded")
            if !alreadyLoaded {
                throw BackgroundAgentError.commandFailed(bootstrapResult.commandDescription, bootstrapResult.combinedOutput)
            }
        }

        let kickstartResult = runner.run(
            executable: SystemTool.launchctl.path,
            arguments: ["kickstart", "-k", serviceTarget]
        )
        if kickstartResult.exitCode != 0 {
            throw BackgroundAgentError.commandFailed(kickstartResult.commandDescription, kickstartResult.combinedOutput)
        }

        return status()
    }

    func disable() -> BackgroundAgentState {
        let plistURL = launchAgentPlistURL
        _ = runner.run(executable: SystemTool.launchctl.path, arguments: ["bootout", domainTarget, plistURL.path])
        _ = runner.run(executable: SystemTool.launchctl.path, arguments: ["disable", serviceTarget])
        return .stopped
    }

    func status() -> BackgroundAgentState {
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

    var launchAgentPlistURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist", isDirectory: false)
    }

    private var serviceTarget: String {
        "\(domainTarget)/\(label)"
    }

    private var domainTarget: String {
        "gui/\(getuid())"
    }

    private var logsDirectoryURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(ProjectMetadata.productName, isDirectory: true)
    }

    private var supportDirectoryURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(ProjectMetadata.productName, isDirectory: true)
    }

    private func bundledDaemonURL(bundle: Bundle = .main) throws -> URL {
        guard let resourceURL = bundle.resourceURL else {
            throw BackgroundAgentError.missingResourceDirectory
        }

        let daemonURL = resourceURL.appendingPathComponent("PrinterBridgeDaemon", isDirectory: false)
        guard fileManager.isExecutableFile(atPath: daemonURL.path) else {
            throw BackgroundAgentError.missingBundledDaemon(daemonURL.path)
        }

        return daemonURL
    }

    private func writeLaunchAgentPlist(configURL: URL) throws -> URL {
        let daemonURL = try bundledDaemonURL()

        try fileManager.createDirectory(at: launchAgentPlistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: supportDirectoryURL, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [daemonURL.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "WorkingDirectory": supportDirectoryURL.path,
            "StandardOutPath": logsDirectoryURL.appendingPathComponent("daemon.log").path,
            "StandardErrorPath": logsDirectoryURL.appendingPathComponent("daemon-error.log").path,
            "EnvironmentVariables": [
                BridgeConfigurationStore.environmentOverrideKey: configURL.path,
            ],
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: launchAgentPlistURL, options: .atomic)
        return launchAgentPlistURL
    }
}

enum BackgroundAgentError: LocalizedError {
    case missingResourceDirectory
    case missingBundledDaemon(String)
    case commandFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .missingResourceDirectory:
            return "The app bundle is missing its resources directory."
        case let .missingBundledDaemon(path):
            return "PrinterBridgeDaemon was not found inside the app bundle at \(path)."
        case let .commandFailed(command, output):
            let normalizedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedOutput.isEmpty {
                return "The background service command failed: \(command)"
            }
            return "The background service command failed: \(command)\n\(normalizedOutput)"
        }
    }
}
