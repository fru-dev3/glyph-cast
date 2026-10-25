// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Capture",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Capture", path: "Sources/Capture")
    ],
    swiftLanguageModes: [.v5]
)
