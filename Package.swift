// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemoteDroid",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "RemoteDroid", targets: ["RemoteDroid"]),
        .library(name: "RemoteDroidCore", targets: ["RemoteDroidCore"]),
    ],
    targets: [
        .target(
            name: "RemoteDroidCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "RemoteDroid",
            dependencies: ["RemoteDroidCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RemoteDroidCoreTests",
            dependencies: ["RemoteDroidCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
