// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FindersKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "FindersKit", targets: ["FindersKit"])],
    dependencies: [.package(path: "../ScanCore")],
    targets: [
        .target(
            name: "FindersKit",
            dependencies: [.product(name: "ScanCore", package: "ScanCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FindersKitTests",
            dependencies: ["FindersKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
