// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SnipCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SnipCore", targets: ["SnipCore"])],
    targets: [
        .target(name: "SnipCore"),
        .testTarget(name: "SnipCoreTests", dependencies: ["SnipCore"])
    ]
)

