// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let exampleProducts: [Product] = [
    .executable(name: "FileMonitorDelegateExample", targets: ["FileMonitorDelegateExample"]),
    .executable(name: "FileMonitorAsyncStreamExample", targets: ["FileMonitorAsyncStreamExample"])
]
let exampleTargets: [Target] = [
    .executableTarget(name: "FileMonitorDelegateExample", dependencies: ["FileMonitor"]),
    .executableTarget(name: "FileMonitorAsyncStreamExample", dependencies: ["FileMonitor"])
]

let package = Package(
    name: "FileMonitor",
    platforms: [
      .macOS(.v14)
    ],
    products: [
        .library(name: "FileMonitor", targets: ["FileMonitor"]),
    ] + exampleProducts,
    dependencies: [
    ],
    targets: [
        .target(
            name: "FileMonitor",
            dependencies: [
                "FileMonitorShared",
                .target(name: "FileMonitorMacOS", condition: .when(platforms: [.macOS])),
                .target(name: "FileMonitorLinux", condition: .when(platforms: [.linux])),
                .target(name: "FileMonitorWindows", condition: .when(platforms: [.windows])),
            ]
        ),
        .target(
            name: "FileMonitorShared",
            path: "Sources/FileMonitorShared"
        ),
        .systemLibrary(name: "CInotify",
                path: "Sources/Inotify"
        ),
        .target(
                name: "FileMonitorLinux",
                dependencies: [
                    .target(name: "CInotify", condition: .when(platforms: [.linux])),
                    "FileMonitorShared"
                ],
                path: "Sources/FileMonitorLinux"
        ),
        .target(
                name: "FileMonitorMacOS",
                dependencies: ["FileMonitorShared"],
                path: "Sources/FileMonitorMacOS"
        ),
        .target(
                name: "FileMonitorWindows",
                dependencies: ["FileMonitorShared"],
                path: "Sources/FileMonitorWindows"
        ),
        .testTarget(
            name: "FileMonitorTests",
            dependencies: ["FileMonitor"]),
    ] + exampleTargets
)
