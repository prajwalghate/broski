// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Broski",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        // Shared with the iPhone app (iOS/project.yml).
        .library(name: "BroskiCore", targets: ["BroskiCore"]),
        // On-device English speech recognition, shared with the iPhone app too.
        .library(name: "BroskiBark", targets: ["BroskiBark"]),
    ],
    targets: [
        // Pure Foundation logic: wake-word matching, note routing, markdown storage.
        .target(name: "BroskiCore"),
        // The menu-bar app: mic + speech recognition, floating panel, hotkey.
        .executableTarget(name: "Broski", dependencies: ["BroskiCore", "BroskiWhisper", "BroskiBark"]),
        // Assertion-based checks for BroskiCore (no XCTest needed with Command Line Tools).
        .executableTarget(name: "BroskiSelfTest", dependencies: ["BroskiCore"]),
        // Unit tests for BroskiCore (Swift Testing): new code is written test-first here.
        .testTarget(name: "BroskiCoreTests", dependencies: ["BroskiCore"]),
        // Local speech-to-text, English: Underdog Bark 3.0 (Core ML on the Neural Engine), with no other dependencies.
        .target(name: "BroskiBark"),
        // Transcribes audio files through BroskiBark: `swift run BarkCheck <model folder> <audio>... [--expect text]`.
        .executableTarget(name: "BarkCheck", dependencies: ["BroskiBark"]),
        // Local speech-to-text: whisper.cpp (Metal) behind a small Swift API.
        .target(name: "BroskiWhisper", dependencies: ["whisper"]),
        // Transcribes an audio file through BroskiWhisper: `swift run WhisperCheck <audio> [model]`.
        .executableTarget(name: "WhisperCheck", dependencies: ["BroskiWhisper"]),
        // Official prebuilt whisper.cpp XCFramework (b5454 == v1.9.5), dynamic framework with Metal.
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
        ),
    ]
)
