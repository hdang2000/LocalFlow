// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LocalFlow",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure text processing and settings models; no AppKit, fully unit-tested.
        .target(name: "LocalFlowCore"),
        // The menu-bar application: hotkeys, audio, whisper server, insertion, UI.
        .executableTarget(
            name: "LocalFlow",
            dependencies: ["LocalFlowCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "LocalFlowCoreTests", dependencies: ["LocalFlowCore"]),
    ]
)
