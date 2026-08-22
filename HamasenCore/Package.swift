// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HamasenCore",
    // Every language, Chinese included, is a real translation in the
    // catalog, so this is the fallback for a language none of them match.
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "HamasenCore", targets: ["HamasenCore"]),
        // Runs the same servers the tests use, for showing the app without
        // pointing it at a real one.
        .executable(name: "DemoServers", targets: ["DemoServers"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.7.0"),
        // Already in the graph through Citadel; declared so the test target
        // can stand up an in-process WebDAV server.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.0"),
        // FTPS wraps the FTP connections in TLS; NIOSSL is what does that.
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
    ],
    targets: [
        // Citadel's SSHClient is not marked Sendable yet, which trips Swift 6
        // strict concurrency; access is serialized by the SFTPFileService
        // actor, so these targets stay on language mode 5 for now.
        .target(
            name: "HamasenCore",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            resources: [.process("Localizable.xcstrings")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The in-process SFTP and FTP servers the client is exercised
        // against. Outside the test target so the demo executable can run
        // the same ones rather than a second copy of them.
        .target(
            name: "HamasenTestServers",
            dependencies: [
                "HamasenCore",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "DemoServers",
            dependencies: ["HamasenTestServers"]
        ),
        .testTarget(
            name: "HamasenCoreTests",
            dependencies: [
                "HamasenCore",
                "HamasenTestServers",
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
