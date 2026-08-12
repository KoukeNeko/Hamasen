import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH
@testable import ServerPathCore

/// In-process SFTP server for tests: a local temp directory as its root and
/// fixed username/password authentication.
///
/// Keeps SFTPFileService tests fully hermetic — no external network, Docker,
/// or sshd required.
///
/// Known limitation: Citadel's server handler swallows delegate errors for
/// stat / opendir / openFile (no response is sent, so the client would wait
/// until timeout). Error-path tests therefore only exercise remove / rename,
/// which report failures via status codes, and the delegate returns empty
/// attributes instead of throwing for nonexistent stat paths. Real OpenSSH
/// servers do not have this problem.
final class TestSFTPServer {
    static let username = "testuser"
    static let password = "testpass"

    private static let portRange = 20000..<60000
    private static let maxBindAttempts = 5

    let port: Int
    let rootDirectory: URL
    private let server: SSHServer

    private init(port: Int, rootDirectory: URL, server: SSHServer) {
        self.port = port
        self.rootDirectory = rootDirectory
        self.server = server
    }

    /// Starts the server; its root is a freshly created temp directory.
    static func start() async throws -> TestSFTPServer {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sftp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())

        var lastError: Error?
        for _ in 0..<maxBindAttempts {
            let candidatePort = Int.random(in: portRange)
            do {
                let server = try await SSHServer.host(
                    host: "127.0.0.1",
                    port: candidatePort,
                    hostKeys: [hostKey],
                    authenticationDelegate: FixedCredentialAuthDelegate()
                )
                server.enableSFTP(withDelegate: DirectoryBackedSFTPDelegate(root: rootDirectory))
                return TestSFTPServer(port: candidatePort, rootDirectory: rootDirectory, server: server)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? RemoteFileServiceError.connectionFailed(underlying: "無法綁定測試埠")
    }

    func stop() async throws {
        try await server.close()
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}

// MARK: - Authentication

private final class FixedCredentialAuthDelegate: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .password

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        guard
            case .password(let passwordRequest) = request.request,
            request.username == TestSFTPServer.username,
            passwordRequest.password == TestSFTPServer.password
        else {
            responsePromise.succeed(.failure)
            return
        }
        responsePromise.succeed(.success)
    }
}

// MARK: - SFTP delegate backed by a local directory

private final class DirectoryBackedSFTPDelegate: SFTPDelegate {
    private let root: URL

    init(root: URL) {
        self.root = root
    }

    // MARK: Path handling

    /// Maps an SFTP path ("/a/b") to a local URL under root, dropping any
    /// ".." components so paths cannot escape the root.
    private func localURL(for sftpPath: String) -> URL {
        let components = sftpPath
            .split(separator: "/")
            .map(String.init)
            .filter { $0 != "." && $0 != ".." }
        var url = root
        for component in components {
            url.appendPathComponent(component)
        }
        return url
    }

    private func canonicalPath(for sftpPath: String) -> String {
        let components = sftpPath
            .split(separator: "/")
            .map(String.init)
            .filter { $0 != "." && $0 != ".." }
        return "/" + components.joined(separator: "/")
    }

    // MARK: Attributes

    private func makeAttributes(forLocalURL url: URL) -> SFTPFileAttributes {
        makeSFTPAttributes(forLocalURL: url)
    }

    // MARK: SFTPDelegate

    func fileAttributes(atPath path: String, context: SSHContext) async throws -> SFTPFileAttributes {
        makeAttributes(forLocalURL: localURL(for: path))
    }

    func openFile(
        _ filePath: String,
        withAttributes: SFTPFileAttributes,
        flags: SFTPOpenFileFlags,
        context: SSHContext
    ) async throws -> SFTPFileHandle {
        let url = localURL(for: filePath)

        if flags.contains(.create), !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        let fileHandle: FileHandle
        if flags.contains(.write) {
            fileHandle = try FileHandle(forUpdating: url)
            if flags.contains(.truncate) {
                try fileHandle.truncate(atOffset: 0)
            }
        } else {
            fileHandle = try FileHandle(forReadingFrom: url)
        }
        return LocalSFTPFileHandle(url: url, fileHandle: fileHandle)
    }

    func removeFile(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode {
        let url = localURL(for: filePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return .noSuchFile }
        try FileManager.default.removeItem(at: url)
        return .ok
    }

    func createDirectory(
        _ filePath: String,
        withAttributes: SFTPFileAttributes,
        context: SSHContext
    ) async throws -> SFTPStatusCode {
        try FileManager.default.createDirectory(
            at: localURL(for: filePath),
            withIntermediateDirectories: false
        )
        return .ok
    }

    func removeDirectory(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode {
        let url = localURL(for: filePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return .noSuchFile }
        try FileManager.default.removeItem(at: url)
        return .ok
    }

    func realPath(for canonicalUrl: String, context: SSHContext) async throws -> [SFTPPathComponent] {
        let path = canonicalPath(for: canonicalUrl)
        return [
            SFTPPathComponent(
                filename: path,
                longname: path,
                attributes: makeAttributes(forLocalURL: localURL(for: path))
            )
        ]
    }

    func openDirectory(atPath path: String, context: SSHContext) async throws -> SFTPDirectoryHandle {
        let url = localURL(for: path)
        let entryNames = try FileManager.default.contentsOfDirectory(atPath: url.path)
        let components = entryNames.map { name in
            SFTPPathComponent(
                filename: name,
                longname: name,
                attributes: makeAttributes(forLocalURL: url.appendingPathComponent(name))
            )
        }
        return LocalSFTPDirectoryHandle(listing: components.isEmpty ? [] : [SFTPFileListing(path: components)])
    }

    func setFileAttributes(
        to attributes: SFTPFileAttributes,
        atPath path: String,
        context: SSHContext
    ) async throws -> SFTPStatusCode {
        .ok
    }

    func addSymlink(linkPath: String, targetPath: String, context: SSHContext) async throws -> SFTPStatusCode {
        .unsupportedOperation
    }

    func readSymlink(atPath path: String, context: SSHContext) async throws -> [SFTPPathComponent] {
        []
    }

    func rename(oldPath: String, newPath: String, flags: UInt32, context: SSHContext) async throws -> SFTPStatusCode {
        let sourceURL = localURL(for: oldPath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return .noSuchFile }
        try FileManager.default.moveItem(at: sourceURL, to: localURL(for: newPath))
        return .ok
    }
}

// MARK: - File and directory handles

/// Reads SFTP attributes from the local file system, adding the S_IFMT bits
/// the client needs to derive the item kind.
private func makeSFTPAttributes(forLocalURL url: URL) -> SFTPFileAttributes {
    guard let fileAttributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
        return SFTPFileAttributes(size: 0)
    }

    let modificationDate = fileAttributes[.modificationDate] as? Date ?? Date()
    var attributes = SFTPFileAttributes(
        size: (fileAttributes[.size] as? NSNumber)?.uint64Value ?? 0,
        accessModificationTime: .init(accessTime: modificationDate, modificationTime: modificationDate)
    )

    let posixPermissions = (fileAttributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644
    let isDirectory = (fileAttributes[.type] as? FileAttributeType) == .typeDirectory
    let fileTypeBits: UInt32 = isDirectory ? 0o040000 : 0o100000
    attributes.permissions = fileTypeBits | posixPermissions
    return attributes
}

private final class LocalSFTPFileHandle: SFTPFileHandle {
    private let url: URL
    private let fileHandle: FileHandle

    init(url: URL, fileHandle: FileHandle) {
        self.url = url
        self.fileHandle = fileHandle
    }

    func read(at offset: UInt64, length: UInt32) async throws -> ByteBuffer {
        try fileHandle.seek(toOffset: offset)
        let data = try fileHandle.read(upToCount: Int(length)) ?? Data()
        return ByteBuffer(bytes: data)
    }

    func write(_ data: ByteBuffer, atOffset offset: UInt64) async throws -> SFTPStatusCode {
        try fileHandle.seek(toOffset: offset)
        let bytes = data.getBytes(at: data.readerIndex, length: data.readableBytes) ?? []
        try fileHandle.write(contentsOf: Data(bytes))
        return .ok
    }

    func close() async throws -> SFTPStatusCode {
        try fileHandle.close()
        return .ok
    }

    func readFileAttributes() async throws -> SFTPFileAttributes {
        makeSFTPAttributes(forLocalURL: url)
    }

    func setFileAttributes(to attributes: SFTPFileAttributes) async throws {
        // Tests never change attributes.
    }
}

private struct LocalSFTPDirectoryHandle: SFTPDirectoryHandle {
    let listing: [SFTPFileListing]

    func listFiles(context: SSHContext) async throws -> [SFTPFileListing] {
        listing
    }
}
