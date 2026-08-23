// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CardVault",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CardVaultCore", targets: ["CardVaultCore"]),
        .executable(name: "CardVault", targets: ["CardVaultApp"])
    ],
    targets: [
        .target(
            name: "CardVaultCore",
            path: "Sources/CardVaultCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "CardVaultApp",
            dependencies: ["CardVaultCore"],
            path: "CardVault",
            exclude: ["CardVault.entitlements"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CardVaultCoreTests",
            dependencies: ["CardVaultCore"],
            path: "CardVaultTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
