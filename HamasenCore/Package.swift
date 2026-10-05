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
        // Pinned to two fixes on top of 0.12.1. The commit of
        // orlandos-nl/Citadel#137: upstream's listDirectory never closes the
        // directory handle, so one SFTP session fails every listing after the
        // server's 1,021st handle. And on top of it, a server that fails stat
        // or lstat answers with a status instead of never answering, which
        // is how the test server reports a missing path. Back to the release
        // line once both are in one.
        .package(url: "https://github.com/KoukeNeko/Citadel.git", revision: "8bf4667ec2c07f5640444e91f83b84cea6542795"),
        // Already in the graph through Citadel; declared so the test target
        // can stand up an in-process WebDAV server.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.0"),
        // FTPS wraps the FTP connections in TLS; NIOSSL is what does that.
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        // SMB 2/3 in Swift, MIT. Pinned past 0.3.1 to the fixes for crashes
        // on partial headers and for large downloads stalling, which are not
        // in a release yet.
        .package(url: "https://github.com/kishikawakatsumi/SMBClient.git", revision: "66eafaa6d17e034e8036dee4b3ebc1b52cb53919"),
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
                .product(name: "SMBClient", package: "SMBClient"),
            ],
            resources: [.process("Localizable.xcstrings")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The in-process SFTP, FTP and S3 servers the client is exercised
        // against. Outside the test target so the demo executable can run
        // the same ones rather than a second copy of them.
        .target(
            name: "HamasenTestServers",
            dependencies: [
                "HamasenCore",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
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
