// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ScreenTrace",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "ScreenTraceCore", targets: ["ScreenTraceCore"]),
        .executable(name: "ScreenTrace", targets: ["ScreenTraceMac"])
    ],
    targets: [
        .target(name: "ScreenTraceCore"),
        .executableTarget(
            name: "ScreenTraceMac",
            dependencies: ["ScreenTraceCore"]
        ),
        .testTarget(
            name: "ScreenTraceCoreTests",
            dependencies: ["ScreenTraceCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "ScreenTraceMacTests",
            dependencies: ["ScreenTraceMac", "ScreenTraceCore"]
        )
    ]
)
