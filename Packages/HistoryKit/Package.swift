// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HistoryKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HistoryKit", targets: ["HistoryKit"])
    ],
    dependencies: [.package(path: "../ScanCore")],
    targets: [
        .target(
            name: "HistoryKit",
            dependencies: [.product(name: "ScanCore", package: "ScanCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "HistoryKitTests",
            dependencies: ["HistoryKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
