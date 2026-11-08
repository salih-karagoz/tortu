// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RulesEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RulesEngine", targets: ["RulesEngine"])
    ],
    dependencies: [.package(path: "../ScanCore"), .package(path: "../SafetyKit")],
    targets: [
        .target(
            name: "RulesEngine",
            dependencies: [.product(name: "ScanCore", package: "ScanCore"), .product(name: "SafetyKit", package: "SafetyKit")],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RulesEngineTests",
            dependencies: ["RulesEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
