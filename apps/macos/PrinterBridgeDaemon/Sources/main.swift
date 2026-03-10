import Foundation
import PrinterBridgeCore

enum PrinterBridgeDaemon {
    static func main() {
        let inventory = PrinterInventoryService()
        print(inventory.renderSnapshot(preferredQueueName: ProjectMetadata.primaryTargetPrinter))
    }
}

PrinterBridgeDaemon.main()
