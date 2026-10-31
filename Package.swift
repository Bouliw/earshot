// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Earshot",
    platforms: [.macOS("26.0")],
    targets: [
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
        ),
        .executableTarget(
            name: "Earshot",
            dependencies: ["whisper"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "EarshotTests", dependencies: ["Earshot"]),
    ],
    swiftLanguageModes: [.v5]
)
