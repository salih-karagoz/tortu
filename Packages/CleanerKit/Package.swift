// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CleanerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CleanerKit", targets: ["CleanerKit"])
    ],
    dependencies: [.package(path: "../RulesEngine"), .package(path: "../HelperProtocol"), .package(path: "../SafetyKit")],
    targets: [
        .target(
            name: "CleanerKit",
            dependencies: [.product(name: "RulesEngine", package: "RulesEngine"), .product(name: "HelperProtocol", package: "HelperProtocol"), .product(name: "SafetyKit", package: "SafetyKit")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CleanerKitTests",
            dependencies: ["CleanerKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
