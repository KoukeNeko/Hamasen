// Copyright 2026 KoukeNeko
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH
import HamasenCore

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
public final class TestSFTPServer {
    public static let username = "testuser"
    public static let password = "testpass"

    private static let portRange = 20000..<60000
    private static let maxBindAttempts = 5

    public let port: Int
    public let rootDirectory: URL
    /// The client key the server accepts, in OpenSSH private key format.
    public let authorizedClientKey: String
    private let server: SSHServer
    private let stall: ReadStall

    /// While set, reads are accepted and never answered — a connection that
    /// has gone half-open, for testing timeouts.
    public var stallsReads: Bool {
        get { stall.isStalled }
        set { stall.isStalled = newValue }
    }

    private init(
        port: Int,
        rootDirectory: URL,
        authorizedClientKey: String,
        server: SSHServer,
        stall: ReadStall
    ) {
        self.port = port
        self.rootDirectory = rootDirectory
        self.authorizedClientKey = authorizedClientKey
        self.server = server
        self.stall = stall
    }

    /// Starts the server; its root is a freshly created temp directory.
    ///
    /// A fresh client key pair is generated per server: the public half is
    /// the only one accepted for key authentication, and the private half is
    /// handed to tests through `authorizedClientKey`.
    /// - Parameter preferredPort: a fixed port, for a server someone is
    ///   going to connect to by hand. Zero picks a free one, which is what
    ///   tests want so they can run side by side.
    public static func start(preferredPort: Int = 0) async throws -> TestSFTPServer {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sftp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let clientKey = Curve25519.Signing.PrivateKey()
        let authorizedKey = try NIOSSHPublicKey(
            openSSHPublicKey: makeOpenSSHPublicKey(clientKey.publicKey)
        )

        let stall = ReadStall()
        var lastError: Error?
        for _ in 0..<maxBindAttempts {
            let candidatePort = preferredPort > 0 ? preferredPort : Int.random(in: portRange)
            do {
                let server = try await SSHServer.host(
                    host: "127.0.0.1",
                    port: candidatePort,
                    hostKeys: [hostKey],
                    authenticationDelegate: FixedCredentialAuthDelegate(authorizedKey: authorizedKey)
                )
                server.enableSFTP(withDelegate: DirectoryBackedSFTPDelegate(root: rootDirectory, stall: stall))
                return TestSFTPServer(
                    port: candidatePort,
                    rootDirectory: rootDirectory,
                    authorizedClientKey: clientKey.makeSSHRepresentation(),
                    server: server,
                    stall: stall
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? RemoteFileServiceError.connectionFailed(underlying: "無法綁定測試埠")
    }

    public func stop() async throws {
        try await server.close()
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}

// MARK: - Authentication

/// Encodes an Ed25519 public key in the OpenSSH `authorized_keys` form:
/// the algorithm name and the key blob, each a length-prefixed SSH string.
private func makeOpenSSHPublicKey(_ publicKey: Curve25519.Signing.PublicKey) -> String {
    let algorithm = "ssh-ed25519"
    var blob = Data()
    for field in [Data(algorithm.utf8), publicKey.rawRepresentation] {
        var length = UInt32(field.count).bigEndian
        withUnsafeBytes(of: &length) { blob.append(contentsOf: $0) }
        blob.append(field)
    }
    return "\(algorithm) \(blob.base64EncodedString()) hamasen-test"
}

private final class FixedCredentialAuthDelegate: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = [.password, .publicKey]

    private let authorizedKey: NIOSSHPublicKey

    init(authorizedKey: NIOSSHPublicKey) {
        self.authorizedKey = authorizedKey
    }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        guard request.username == TestSFTPServer.username else {
            responsePromise.succeed(.failure)
            return
        }

        switch request.request {
        case .password(let passwordRequest):
            responsePromise.succeed(passwordRequest.password == TestSFTPServer.password ? .success : .failure)
        case .publicKey(let publicKeyRequest):
            responsePromise.succeed(publicKeyRequest.publicKey == authorizedKey ? .success : .failure)
        case .hostBased, .none:
            responsePromise.succeed(.failure)
        }
    }
}

// MARK: - SFTP delegate backed by a local directory

private final class DirectoryBackedSFTPDelegate: SFTPDelegate {
    private let root: URL
    private let stall: ReadStall

    init(root: URL, stall: ReadStall) {
        self.root = root
        self.stall = stall
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

    private func makeAttributes(forLocalURL url: URL, followingLinks: Bool = false) -> SFTPFileAttributes {
        makeSFTPAttributes(forLocalURL: url, followingLinks: followingLinks)
    }

    // MARK: SFTPDelegate

    func fileAttributes(atPath path: String, context: SSHContext) async throws -> SFTPFileAttributes {
        let url = localURL(for: path)
        // A missing path is reported as one, as a real server does; answering
        // with empty attributes made every new upload look like a collision.
        // stat follows a symlink, so a dangling one is missing too.
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SFTPMessage.Status(requestId: 0, errorCode: .noSuchFile, message: "No such file", languageTag: "en")
        }
        // stat follows a symlink, as a real server's does; only directory
        // listings describe the link itself.
        return makeAttributes(forLocalURL: url, followingLinks: true)
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
        return LocalSFTPFileHandle(url: url, fileHandle: fileHandle, stall: stall)
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

    /// rmdir(2), as OpenSSH's server calls it: a directory with anything
    /// left in it stays, and the client hears the same generic failure.
    func removeDirectory(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode {
        let url = localURL(for: filePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return .noSuchFile }
        return rmdir(url.path) == 0 ? .ok : .failure
    }

    func realPath(for canonicalUrl: String, context: SSHContext) async throws -> [SFTPPathComponent] {
        let path = canonicalPath(for: canonicalUrl)
        return [
            SFTPPathComponent(
                filename: path,
                longname: path,
                attributes: makeAttributes(forLocalURL: localURL(for: path), followingLinks: true)
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
        // A plain SFTP rename refuses an existing destination, with the same
        // generic failure OpenSSH gives.
        guard !FileManager.default.fileExists(atPath: localURL(for: newPath).path) else { return .failure }
        try FileManager.default.moveItem(at: sourceURL, to: localURL(for: newPath))
        return .ok
    }
}

// MARK: - File and directory handles

/// Reads SFTP attributes from the local file system, adding the S_IFMT bits
/// the client needs to derive the item kind.
private func makeSFTPAttributes(forLocalURL url: URL, followingLinks: Bool = false) -> SFTPFileAttributes {
    let url = followingLinks ? url.resolvingSymlinksInPath() : url
    guard let fileAttributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
        return SFTPFileAttributes(size: 0)
    }

    let modificationDate = fileAttributes[.modificationDate] as? Date ?? Date()
    var attributes = SFTPFileAttributes(
        size: (fileAttributes[.size] as? NSNumber)?.uint64Value ?? 0,
        accessModificationTime: .init(accessTime: modificationDate, modificationTime: modificationDate)
    )

    let posixPermissions = (fileAttributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644
    let fileTypeBits: UInt32
    switch fileAttributes[.type] as? FileAttributeType {
    case .typeDirectory: fileTypeBits = 0o040000
    case .typeSymbolicLink: fileTypeBits = 0o120000
    default: fileTypeBits = 0o100000
    }
    attributes.permissions = fileTypeBits | posixPermissions
    return attributes
}

/// A switch that holds reads unanswered while it is on.
private final class ReadStall: @unchecked Sendable {
    private let lock = NSLock()
    private var stalled = false

    var isStalled: Bool {
        get { lock.withLock { stalled } }
        set { lock.withLock { stalled = newValue } }
    }

    func waitWhileStalled() async throws {
        while isStalled {
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

private final class LocalSFTPFileHandle: SFTPFileHandle {
    private let url: URL
    private let fileHandle: FileHandle
    private let stall: ReadStall

    init(url: URL, fileHandle: FileHandle, stall: ReadStall) {
        self.url = url
        self.fileHandle = fileHandle
        self.stall = stall
    }

    func read(at offset: UInt64, length: UInt32) async throws -> ByteBuffer {
        try await stall.waitWhileStalled()
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
