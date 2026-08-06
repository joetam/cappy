// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cappy",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QuotaContracts", targets: ["QuotaContracts"]),
        .library(name: "QuotaProviderKit", targets: ["QuotaProviderKit"]),
        .executable(name: "quota-appserver", targets: ["QuotaAppServer"]),
        .executable(name: "quota-adapter-codex", targets: ["QuotaAdapterCodex"]),
        .executable(name: "quota-adapter-claude", targets: ["QuotaAdapterClaude"]),
        .executable(name: "quota", targets: ["QuotaCLI"]),
        .executable(name: "CappyMenu", targets: ["CappyMenu"]),
        .executable(name: "quota-selftest", targets: ["QuotaSelfTest"]),
    ],
    targets: [
        .target(name: "QuotaContracts"),
        .target(name: "QuotaProviderKit", dependencies: ["QuotaContracts"]),
        .target(name: "QuotaBuiltins", dependencies: ["QuotaContracts", "QuotaProviderKit"]),
        .executableTarget(name: "QuotaAdapterCodex", dependencies: ["QuotaContracts", "QuotaProviderKit", "QuotaBuiltins"]),
        .executableTarget(name: "QuotaAdapterClaude", dependencies: ["QuotaContracts", "QuotaProviderKit", "QuotaBuiltins"]),
        .target(
            name: "QuotaAppServerCore",
            dependencies: ["QuotaContracts", "QuotaProviderKit"],
            path: "Sources/QuotaAppServer"
        ),
        .executableTarget(
            name: "QuotaAppServer",
            dependencies: ["QuotaAppServerCore"],
            path: "Sources/QuotaAppServerMain"
        ),
        .executableTarget(name: "QuotaCLI", dependencies: ["QuotaContracts", "QuotaProviderKit", "QuotaBuiltins"]),
        .executableTarget(name: "CappyMenu", dependencies: ["QuotaContracts", "QuotaProviderKit"]),
        .executableTarget(name: "QuotaSelfTest", dependencies: ["QuotaContracts", "QuotaProviderKit", "QuotaBuiltins"]),
    ]
)
