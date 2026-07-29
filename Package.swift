// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIListener",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AIListenerCore", targets: ["AIListenerCore"]),
        .executable(name: "AIListenerApp", targets: ["AIListenerApp"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(
            name: "AIListenerCore",
            dependencies: ["CSQLite"]
        ),
        .executableTarget(
            name: "AIListenerApp",
            dependencies: ["AIListenerCore"]
        ),
        .testTarget(
            name: "AIListenerCoreTests",
            dependencies: ["AIListenerCore"]
        ),
    ]
)
