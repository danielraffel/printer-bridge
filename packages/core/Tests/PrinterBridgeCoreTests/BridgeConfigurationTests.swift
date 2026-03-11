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

@Test
func configurationStoreLoadsLegacyConfigurationWithoutBackgroundFlag() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

    let configURL = temporaryDirectory.appendingPathComponent("bridge-config.json", isDirectory: false)
    let legacyJSON = """
    {
      "exposureMode" : "direct-cups",
      "isEnabled" : false,
      "selectedQueueName" : "Brother_HL_2170W_series"
    }
    """
    let legacyData = try #require(legacyJSON.data(using: .utf8))
    try legacyData.write(to: configURL)

    let store = BridgeConfigurationStore(configURL: configURL)
    let loaded = try store.load()

    #expect(loaded.exposureMode == .directCUPS)
    #expect(loaded.keepRunningInBackground == true)
    #expect(loaded.selectedQueueName == "Brother_HL_2170W_series")
    #expect(loaded.printers.count == 1)
    #expect(loaded.printers.first?.queueName == "Brother_HL_2170W_series")
    #expect(loaded.printers.first?.proxyPort == ProjectMetadata.defaultProxyPort)
}

@Test
func configurationNormalizesManagedPrintersAndAllocatesDistinctProxyPorts() {
    var configuration = BridgeConfiguration(
        selectedQueueName: " Brother_HL_2170W_series ",
        printers: [
            ManagedPrinterConfiguration(queueName: " Brother_HL_2170W_series ", isEnabled: true, proxyPort: nil),
            ManagedPrinterConfiguration(queueName: "Office_Printer", isEnabled: true, proxyPort: ProjectMetadata.defaultProxyPort),
            ManagedPrinterConfiguration(queueName: "Office_Printer", isEnabled: false, proxyPort: 8639),
        ],
        exposureMode: .proxy
    )

    configuration.normalize()

    #expect(configuration.selectedQueueName == "Brother_HL_2170W_series")
    #expect(configuration.printers.count == 2)
    #expect(configuration.printers.map(\.queueName) == ["Brother_HL_2170W_series", "Office_Printer"])
    #expect(Set(configuration.printers.compactMap(\.proxyPort)).count == 2)
}

@Test
func configurationSetEnabledCreatesManagedPrinterEntry() {
    var configuration = BridgeConfiguration(selectedQueueName: "Hallway_Printer")

    configuration.setEnabled(true, forQueueNamed: "Hallway_Printer")

    #expect(configuration.printers.count == 1)
    #expect(configuration.printers.first?.queueName == "Hallway_Printer")
    #expect(configuration.printers.first?.isEnabled == true)
}

@Test
func configurationNormalizesLegacyPrinterBridgeSpacingInAdvertisedName() {
    var configuration = BridgeConfiguration(
        selectedQueueName: "Brother_HL_2170W_series",
        printers: [
            ManagedPrinterConfiguration(
                queueName: "Brother_HL_2170W_series",
                isEnabled: true,
                advertisedNameOverride: "Brother HL-2170W series via PrinterBridge",
                proxyPort: ProjectMetadata.defaultProxyPort
            )
        ],
        exposureMode: .proxy
    )

    configuration.normalize()

    #expect(configuration.printers.first?.advertisedNameOverride == "Brother HL-2170W series via Printer Bridge")
}
