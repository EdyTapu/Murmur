// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5")
    ],
    targets: [
        .executableTarget(
            name: "Murmur",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/Murmur"
        ),
        .executableTarget(
            name: "murmur-cli",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/MurmurCLI"
        ),
        .testTarget(
            name: "MurmurTests",
            dependencies: ["Murmur"],
            path: "Tests/MurmurTests"
        )
    ]
)
