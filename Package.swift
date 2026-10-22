// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Lar",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Lar", targets: ["Lar"]),
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
