// swift-tools-version: 6.0
import PackageDescription

// End-to-end tests of HamasenCore's clients against real servers in Docker.
//
// A package of its own so that `swift test` in HamasenCore stays hermetic and
// quick: everything here needs `scripts/e2e.sh up` first, and is skipped
// unless HAMASEN_E2E=1.
let package = Package(
    name: "HamasenE2E",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../HamasenCore"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
    ],
    targets: [
        .testTarget(
            name: "HamasenE2ETests",
            dependencies: [
                .product(name: "HamasenCore", package: "HamasenCore"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            // HamasenCore is built in language mode 5 for Citadel; the tests
            // reach its internals, so they follow it.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
