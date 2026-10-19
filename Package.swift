// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Minutes",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Minutes", targets: ["Minutes"]),
    ],
    targets: [
        // Pure, deterministic logic: detection, storage layout, transcription assembly, Groq client.
        .target(name: "MinutesCore"),
        // macOS capture: Core Audio process tap, microphone, ScreenCaptureKit window video, audio files.
        .target(
            name: "MinutesCapture",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Menu bar app: orchestration, settings, keychain, notifications.
        .executableTarget(
            name: "Minutes",
            dependencies: ["MinutesCore", "MinutesCapture"]
        ),
        .testTarget(name: "MinutesCoreTests", dependencies: ["MinutesCore"]),
        .testTarget(name: "MinutesTests", dependencies: ["Minutes", "MinutesCore", "MinutesCapture"]),
    ]
)
