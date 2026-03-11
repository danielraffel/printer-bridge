import Testing
@testable import PrinterBridgeCore

@Test
func productIdentityMatchesRepoPlan() {
    #expect(ProjectMetadata.productName == "PrinterBridge")
    #expect(ProjectMetadata.appDisplayName == "Printer Bridge")
    #expect(ProjectMetadata.appStoreName == "Printer Bridge for AirPrint")
    #expect(ProjectMetadata.repositorySlug == "printer-bridge")
    #expect(ProjectMetadata.minimumSupportedMacOS == "15.0")
    #expect(ProjectMetadata.primaryTargetPrinter == "Brother_HL_2170W_series")
}

@Test
func developmentTopologyIncludesRemoteVerificationHost() {
    #expect(DevelopmentTopology.hosts.count == 2)
    #expect(DevelopmentTopology.hosts.last?.accessCommand == "ssh macmini")
    #expect(ProjectMetadata.verificationHostAlias == "macmini")
}

@Test
func smokeTestPassesForCurrentScaffold() {
    let result = ProjectDiagnostics.smokeTest()

    #expect(result.success)
    #expect(result.output.contains("smoke test: passed"))
}
