// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Entitlements",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Entitlements", targets: ["Entitlements"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Entitlements",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "EntitlementsTests",
            dependencies: ["Entitlements"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
