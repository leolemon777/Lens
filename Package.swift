// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Lens",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "LensCore", targets: ["LensCore"]),
        .executable(name: "Lens", targets: ["LensMac"])
    ],
    targets: [
        .target(name: "LensCore"),
        .executableTarget(
            name: "LensMac",
            dependencies: ["LensCore"]
        ),
        .testTarget(
            name: "LensCoreTests",
            dependencies: ["LensCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "LensMacTests",
            dependencies: ["LensMac", "LensCore"]
        )
    ]
)
