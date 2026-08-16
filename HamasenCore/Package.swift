// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HamasenCore",
    // The user-facing error strings are written in Traditional Chinese and
    // are their own catalog keys, so that is the language they fall back to.
    defaultLocalization: "zh-Hant",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "HamasenCore", targets: ["HamasenCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.7.0"),
        // Already in the graph through Citadel; declared so the test target
        // can stand up an in-process WebDAV server.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.0"),
    ],
    targets: [
        // Citadel's SSHClient is not marked Sendable yet, which trips Swift 6
        // strict concurrency; access is serialized by the SFTPFileService
        // actor, so these targets stay on language mode 5 for now.
        .target(
            name: "HamasenCore",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
            ],
            resources: [.process("Localizable.xcstrings")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HamasenCoreTests",
            dependencies: [
                "HamasenCore",
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
