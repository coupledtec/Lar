// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Lar",
    platforms: [.macOS(.v15), .iOS(.v18), .watchOS(.v11), .visionOS(.v2), .tvOS(.v18)],
    products: [
        .executable(name: "Lar", targets: ["Lar"]),
        .library(name: "LarCore", targets: ["LarCore"]),
    ],
    targets: [
        .target(name: "LarCore"),
        .executableTarget(name: "Lar", dependencies: ["LarCore"]),
        .testTarget(
            name: "LarCoreTests",
            dependencies: ["LarCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
