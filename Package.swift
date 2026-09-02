// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Lens",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS("15.2")
    ],
    products: [
        .library(name: "LensCore", targets: ["LensCore"]),
        .library(name: "LensMac", targets: ["LensMac"]),
        .executable(name: "Lens", targets: ["Lens"]),
        .executable(name: "LensG1", targets: ["LensG1"]),
        .executable(name: "LensG2", targets: ["LensG2"]),
        .executable(name: "LensG3", targets: ["LensG3"]),
        .executable(name: "LensG4", targets: ["LensG4"])
    ],
    targets: [
        .target(name: "LensCore"),
        .target(
            name: "LensMac",
            dependencies: ["LensCore"]
        ),
        .executableTarget(
            name: "Lens",
            dependencies: ["LensMac"]
        ),
        .executableTarget(
            name: "LensG1",
            dependencies: ["LensMac"]
        ),
        .executableTarget(
            name: "LensG2",
            dependencies: ["LensMac"]
        ),
        .executableTarget(
            name: "LensG3",
            dependencies: ["LensMac"]
        ),
        .executableTarget(
            name: "LensG4",
            dependencies: ["LensMac"]
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
