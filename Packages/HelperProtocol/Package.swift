// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HelperProtocol",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HelperProtocol", targets: ["HelperProtocol"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "HelperProtocol",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "HelperProtocolTests",
            dependencies: ["HelperProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
