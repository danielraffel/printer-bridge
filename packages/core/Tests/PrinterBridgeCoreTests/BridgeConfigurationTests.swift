import Foundation
import Testing
@testable import PrinterBridgeCore

@Test
func configurationStoreRoundTripsConfiguration() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

    let configURL = temporaryDirectory.appendingPathComponent("bridge-config.json", isDirectory: false)
    let store = BridgeConfigurationStore(configURL: configURL)
    let expected = BridgeConfiguration(
        isEnabled: true,
        selectedQueueName: "Brother_HL_2170W_series",
        advertisedNameOverride: "Hallway Brother",
        exposureMode: .directCUPS
    )

    try store.save(expected)
    let loaded = try store.load()

    #expect(loaded == expected)
}

@Test
func configurationStoreSupportsEnvironmentOverride() {
    let store = BridgeConfigurationStore(environment: [
        BridgeConfigurationStore.environmentOverrideKey: "/tmp/printerbridge-test-config.json"
    ])

    #expect(store.configURL.path == "/tmp/printerbridge-test-config.json")
}
