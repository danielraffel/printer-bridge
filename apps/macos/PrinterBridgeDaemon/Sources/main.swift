import Foundation
import PrinterBridgeCore

enum PrinterBridgeDaemon {
    static func main() {
        let message = """
        \(ProjectMetadata.productName) daemon scaffold
        verification host alias: \(ProjectMetadata.verificationHostAlias)
        primary target printer: \(ProjectMetadata.primaryTargetPrinter)
        status: placeholder implementation
        """

        print(message)
    }
}

PrinterBridgeDaemon.main()
