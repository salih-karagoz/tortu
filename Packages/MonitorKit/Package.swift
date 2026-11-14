// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MonitorKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MonitorKit", targets: ["MonitorKit"])],
    dependencies: [.package(path: "../ScanCore")],
    targets: [
        .target(
            name: "MonitorKit",
            dependencies: [.product(name: "ScanCore", package: "ScanCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MonitorKitTests",
            dependencies: ["MonitorKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
