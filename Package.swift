// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClipboardAnnotator",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "ClipboardAnnotatorDomain",
            targets: ["ClipboardAnnotatorDomain"]
        ),
        .executable(
            name: "ClipboardAnnotator",
            targets: ["ClipboardAnnotator"]
        ),
    ],
    dependencies: [
        // Hex uses FluidAudio for its fast, local Parakeet transcription.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5"),
    ],
    targets: [
        .target(
            name: "ClipboardAnnotatorDomain",
            path: "Sources/ClipboardAnnotatorDomain"
        ),
        .executableTarget(
            name: "ClipboardAnnotator",
            dependencies: ["ClipboardAnnotatorDomain", "FluidAudio"],
            path: "Sources/ClipboardAnnotator"
        ),
        .testTarget(
            name: "ClipboardAnnotatorDomainTests",
            dependencies: ["ClipboardAnnotatorDomain"],
            path: "Tests/ClipboardAnnotatorDomainTests"
        ),
    ]
)
