// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BeQuiet",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MicMonitor", targets: ["MicMonitor"]),
        .library(name: "MediaControl", targets: ["MediaControl"]),
        .library(name: "BeQuietCore", targets: ["BeQuietCore"]),
        .executable(name: "bequiet", targets: ["BeQuietCLI"]),
    ],
    targets: [
        .target(
            name: "MicMonitor",
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        .target(name: "MediaControl"),
        .target(
            name: "BeQuietCore",
            dependencies: ["MediaControl", "MicMonitor"]
        ),
        .executableTarget(
            name: "BeQuietCLI",
            dependencies: ["BeQuietCore", "MediaControl", "MicMonitor"]
        ),
        .testTarget(
            name: "BeQuietCoreTests",
            dependencies: ["BeQuietCore"]
        ),
        .testTarget(
            name: "MediaControlTests",
            dependencies: ["MediaControl"]
        ),
    ]
)
