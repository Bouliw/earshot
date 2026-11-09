// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Earshot",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Speaker separation only: no text-to-speech, no text normalization engine.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3", traits: ["Diarizer"]),
    ],
    targets: [
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
        ),
        .executableTarget(
            name: "Earshot",
            dependencies: ["whisper", .product(name: "FluidAudio", package: "FluidAudio")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "EarshotTests", dependencies: ["Earshot"]),
    ],
    swiftLanguageModes: [.v5]
)
