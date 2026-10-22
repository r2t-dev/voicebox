// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Voicebox",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "Voicebox", targets: ["Voicebox"])
    ],
    dependencies: [
        // Pinned: FluidAudio renamed the ASR setup call between releases
        // (initialize, configure, loadModels). This code follows the v0.17.7 README.
        // `traits: []` leaves out the prebuilt NemoTextProcessing binary, which ASR does not need.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: [])
    ],
    targets: [
        .target(
            name: "VoiceboxCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .executableTarget(
            name: "Voicebox",
            dependencies: ["VoiceboxCore"]
        ),
        .testTarget(
            name: "VoiceboxCoreTests",
            dependencies: ["VoiceboxCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
