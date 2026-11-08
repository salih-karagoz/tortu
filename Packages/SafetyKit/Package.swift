// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SafetyKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SafetyKit", targets: ["SafetyKit"])
    ],
    dependencies: [.package(path: "../ScanCore")],
    targets: [
        .target(
            name: "SafetyKit",
            dependencies: [.product(name: "ScanCore", package: "ScanCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SafetyKitTests",
            dependencies: ["SafetyKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
