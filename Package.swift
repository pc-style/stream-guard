// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "PIIGuard",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PIIGuardCore", targets: ["PIIGuardCore"]),
        .executable(name: "PIIGuard", targets: ["PIIGuard"]),
        .executable(name: "pii-guard", targets: ["PIIGuardCLI"]),
        .executable(name: "PIIGuardVerifier", targets: ["PIIGuardVerifier"])
    ],
    targets: [
        .target(name: "PIIGuardCore"),
        .executableTarget(name: "PIIGuard", dependencies: ["PIIGuardCore"]),
        .executableTarget(name: "PIIGuardCLI", dependencies: ["PIIGuardCore"]),
        .executableTarget(name: "PIIGuardVerifier", dependencies: ["PIIGuardCore"])
    ],
    swiftLanguageModes: [.v5]
)
