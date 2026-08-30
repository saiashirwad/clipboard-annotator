// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClipboardAnnotator",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Hex uses FluidAudio for its fast, local Parakeet transcription.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5"),
    ],
    targets: [
        .executableTarget(
            name: "ClipboardAnnotator",
            dependencies: ["FluidAudio"],
            path: "Sources/ClipboardAnnotator"
        )
    ]
)
