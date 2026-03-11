import Testing
@testable import PrinterBridgeCore

@Test
func bonjourRegistrationCommandUsesAirPrintSubtypeAndTXTRecords() {
    let plan = AirPrintAdvertisementPlan(
        serviceName: "Hallway Brother",
        hostName: "test-host.local",
        port: 631,
        resourcePath: "/printers/Brother_HL_2170W_series",
        printerURI: "ipp://test-host.local:631/printers/Brother_HL_2170W_series",
        backingQueueName: "Brother_HL_2170W_series",
        exposureMode: .directCUPS,
        txtRecords: [
            .init(key: "txtvers", value: "1"),
            .init(key: "rp", value: "printers/Brother_HL_2170W_series"),
            .init(key: "pdl", value: "application/pdf,image/urf,image/pwg-raster"),
        ],
        warnings: []
    )

    let command = BonjourRegistrationCommand(advertisementPlan: plan)

    #expect(command.executable == "/usr/bin/dns-sd")
    #expect(command.arguments == [
        "-R",
        "Hallway Brother",
        "_ipp._tcp,_universal",
        ".",
        "631",
        "txtvers=1",
        "rp=printers/Brother_HL_2170W_series",
        "pdl=application/pdf,image/urf,image/pwg-raster",
    ])
}

@Test
func bridgeStatusSnapshotReportsPublishableOnlyWhenReadyAndEnabled() {
    let advertisement = AirPrintAdvertisementPlan(
        serviceName: "Hallway Brother",
        hostName: "test-host.local",
        port: 631,
        resourcePath: "/printers/Brother_HL_2170W_series",
        printerURI: "ipp://test-host.local:631/printers/Brother_HL_2170W_series",
        backingQueueName: "Brother_HL_2170W_series",
        exposureMode: .directCUPS,
        txtRecords: [],
        warnings: []
    )
    let managedPrinter = ManagedPrinterStatus(
        configuration: ManagedPrinterConfiguration(
            queueName: "Brother_HL_2170W_series",
            isEnabled: true,
            proxyPort: 8631
        ),
        inspection: nil,
        activationState: .ready,
        message: "Ready",
        advertisement: advertisement
    )
    let snapshot = BridgeStatusSnapshot(
        configuration: BridgeConfiguration(isEnabled: true, selectedQueueName: "Brother_HL_2170W_series"),
        availableQueues: [],
        managedPrinters: [managedPrinter],
        selectedPrinter: managedPrinter
    )

    #expect(snapshot.isPublishable == true)
    #expect(snapshot.configuration.isEnabled == true)
}
