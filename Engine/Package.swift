// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "PushUpsEngine",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "PushUpsEngine", targets: ["PushUpsEngine"]),
        .executable(name: "pushups-cli", targets: ["pushups-cli"]),
    ],
    targets: [
        .target(name: "PushUpsEngine"),
        .executableTarget(name: "pushups-cli", dependencies: ["PushUpsEngine"]),
        .testTarget(name: "PushUpsEngineTests", dependencies: ["PushUpsEngine"]),
    ]
)
