// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Lar",
    platforms: [.macOS(.v15), .iOS(.v18), .watchOS(.v11), .visionOS(.v2), .tvOS(.v18)],
    products: [
        .executable(name: "Lar", targets: ["Lar"]),
        .executable(name: "LarWidgets", targets: ["LarWidgets"]),
        .library(name: "LarCore", targets: ["LarCore"]),
    ],
    targets: [
        .target(name: "LarCore"),
        .executableTarget(name: "Lar", dependencies: ["LarCore"]),
        // The Mac's widgets, packed into Lar.app as an extension by scripts/build-app.sh.
        .executableTarget(name: "LarWidgets", dependencies: ["LarCore"]),
        .testTarget(
            name: "LarCoreTests",
            dependencies: ["LarCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
