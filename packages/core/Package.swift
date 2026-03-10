// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PrinterBridgeCore",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "PrinterBridgeCore",
            targets: ["PrinterBridgeCore"]
        ),
    ],
    targets: [
        .target(
            name: "PrinterBridgeCore"
        ),
        .testTarget(
            name: "PrinterBridgeCoreTests",
            dependencies: ["PrinterBridgeCore"]
        ),
    ]
)
