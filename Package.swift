// swift-tools-version: 5.9
import Foundation
import PackageDescription

let infoPlist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/MacMic/Info.plist")
    .path

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
            dependencies: ["QuadcastKit"],
            exclude: ["Info.plist"],
            // Embedded so a bare `swift run` / Xcode-run executable gets the
            // app's bundle identifier (and so its UserDefaults domain) and its
            // NSMicrophoneUsageDescription; scripts/make-app.sh copies the same
            // file into the bundle.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist])
            ]
        ),
        .executableTarget(
            name: "macmic-cli",
            dependencies: ["QuadcastKit"]
        ),
        .testTarget(
            name: "QuadcastKitTests",
            dependencies: ["QuadcastKit", "MacMic", "macmic-cli"]
        )
    ]
)
