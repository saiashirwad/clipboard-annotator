// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClipboardAnnotator",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClipboardAnnotator",
            path: "Sources/ClipboardAnnotator"
        )
    ]
)
