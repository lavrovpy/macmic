// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacMic",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "QuadcastKit"
        ),
        .executableTarget(
            name: "MacMic",
            dependencies: ["QuadcastKit"]
        ),
        .executableTarget(
            name: "macmic-cli",
            dependencies: ["QuadcastKit"]
        ),
        .testTarget(
            name: "QuadcastKitTests",
            dependencies: ["QuadcastKit"]
        )
    ]
)
