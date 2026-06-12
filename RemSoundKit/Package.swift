// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RemSoundKit",
    platforms: [
        .iOS("18.0"),
        .macOS("15.0"),
    ],
    products: [
        .library(name: "RemSoundKit", targets: ["RemSoundKit"]),
    ],
    dependencies: [
        // libopus built from source via SPM. We use the raw C API (Copus module) because the
        // receive path needs opus_decode's decode_fec flag for single-packet-loss recovery,
        // which Apple's AudioConverter Opus decoder does not expose.
        .package(url: "https://github.com/alta/swift-opus.git", exact: "0.0.2"),
    ],
    targets: [
        // Non-variadic C wrappers over opus_encoder_ctl for the send path — Swift cannot
        // call C-variadic functions, so encoder configuration (bitrate, FEC, …) goes
        // through these fixed-signature shims.
        .target(
            name: "RemOpusShim",
            dependencies: [
                .product(name: "Copus", package: "swift-opus"),
            ]
        ),
        .target(
            name: "RemSoundKit",
            dependencies: [
                .product(name: "Opus", package: "swift-opus"),
                "RemOpusShim",
            ]
        ),
        .testTarget(
            name: "RemSoundKitTests",
            dependencies: ["RemSoundKit"]
        ),
    ]
)
