// swift-tools-version: 5.9
import PackageDescription

// Platform-independent editing engine: transcript + loudness in, edit decisions out.
// No AVFoundation here, so it builds and tests on macOS, iOS and Linux.
let package = Package(
    name: "EaseaCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "EaseaCore", targets: ["EaseaCore"]),
    ],
    targets: [
        .target(name: "EaseaCore"),
        .testTarget(name: "EaseaCoreTests", dependencies: ["EaseaCore"]),
    ]
)
