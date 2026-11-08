// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScanCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScanCore", targets: ["ScanCore"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ScanCore",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ScanCoreTests",
            dependencies: ["ScanCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
