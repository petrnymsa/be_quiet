// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BeQuiet",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MicMonitor", targets: ["MicMonitor"]),
        .executable(name: "bequiet", targets: ["BeQuietCLI"]),
    ],
    targets: [
        .target(
            name: "MicMonitor",
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        .executableTarget(
            name: "BeQuietCLI",
            dependencies: ["MicMonitor"]
        ),
    ]
)
