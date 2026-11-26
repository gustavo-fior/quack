// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Quack",
    // macOS 26 is the first release with Liquid Glass, which the interface is built on.
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Quack", path: "Sources/Quack")
    ],
    swiftLanguageModes: [.v5]
)
