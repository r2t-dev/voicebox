// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MiniRecorder",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "MiniRecorder", targets: ["MiniRecorder"])
    ],
    dependencies: [
        // Pinned: FluidAudio renamed the ASR setup call between releases
        // (initialize, configure, loadModels). This code follows the v0.17.7 README.
        // `traits: []` leaves out the prebuilt NemoTextProcessing binary, which ASR does not need.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: [])
    ],
    targets: [
        .target(
            name: "MiniRecorderCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .executableTarget(
            name: "MiniRecorder",
            dependencies: ["MiniRecorderCore"]
        ),
        .testTarget(
            name: "MiniRecorderCoreTests",
            dependencies: ["MiniRecorderCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
