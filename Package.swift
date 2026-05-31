// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StreamGuard",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "StreamGuard", targets: ["StreamGuard"]),
        .executable(name: "StreamGuardTestRunner", targets: ["StreamGuardTestRunner"]),
        .library(name: "StreamGuardCore", targets: ["StreamGuardCore"]),
    ],
    targets: [
        .target(
            name: "StreamGuardCore",
            path: "Sources/StreamGuardCore"
        ),
        .executableTarget(
            name: "StreamGuard",
            dependencies: ["StreamGuardCore"],
            path: "Sources/StreamGuard",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("Network"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
            ]
        ),
        .executableTarget(
            name: "StreamGuardTestRunner",
            dependencies: ["StreamGuardCore"],
            path: "Sources/StreamGuardTestRunner"
        ),
    ]
)
