// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SpaceApps",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "SpaceApps",
            // App code runs on the main thread unless you say otherwise.
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
