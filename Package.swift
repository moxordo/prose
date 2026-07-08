// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "prose",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ProseKit", targets: ["ProseKit"]),
        .executable(name: "prose", targets: ["prose"]),
    ],
    targets: [
        .target(
            name: "ProseKit",
            swiftSettings: [
                // v5 language mode: pragmatic concurrency for an AppKit app that
                // mixes global event monitors, async URLSession, and @MainActor UI.
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "prose",
            dependencies: ["ProseKit"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "ProseKitTests",
            dependencies: ["ProseKit"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
