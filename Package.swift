// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIListener",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AIListenerCore", targets: ["AIListenerCore"]),
        .executable(name: "AIListenerApp", targets: ["AIListenerApp"]),
        .executable(name: "AIListenerASRStress", targets: ["AIListenerASRStress"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(
            name: "CSherpaShim",
            linkerSettings: [.linkedLibrary("dl")]
        ),
        .target(
            name: "ObjCExceptionBridge",
            path: "Sources/ObjCExceptionBridge",
            publicHeadersPath: "include"
        ),
        .target(
            name: "AIListenerCore",
            dependencies: ["CSQLite", "CSherpaShim", "ObjCExceptionBridge"]
        ),
        .executableTarget(
            name: "AIListenerApp",
            dependencies: ["AIListenerCore"]
        ),
        .executableTarget(
            name: "AIListenerASRStress",
            dependencies: ["AIListenerCore"]
        ),
        .testTarget(
            name: "AIListenerCoreTests",
            dependencies: ["AIListenerCore", "ObjCExceptionBridge"]
        ),
    ]
)
