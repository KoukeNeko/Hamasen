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

/// How a server's identity is checked before anything is sent to it.
public enum HostKeyPolicy: Sendable {
    /// Record the first key an endpoint presents and refuse a different one
    /// afterwards. Without a key distributed some other way, this is what
    /// can be checked: it cannot tell a rebuilt server from someone standing
    /// in the middle on the first connection, but it catches either of them
    /// appearing later.
    case trustOnFirstUse(KnownHostsStore)
    /// The record could not be opened, so nothing can be compared against
    /// it. Connections are refused rather than made unverified.
    case unverifiable(reason: String)
    /// No check at all. For a server the caller started itself, which is to
    /// say tests.
    case acceptAnything
}

/// The fingerprint OpenSSH prints, so what this app shows can be compared
/// with `ssh-keyscan` or the server's own `ssh-keygen -lf` output.
public enum HostKeyFingerprint {
    /// SHA-256 of the key in SSH wire format, base64 without padding.
    public static func sha256(of hostKey: NIOSSHPublicKey) -> String {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        hostKey.write(to: &buffer)
        let keyBytes = Data(buffer.readableBytesView)
        let encoded = Data(SHA256.hash(data: keyBytes))
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return "SHA256:\(encoded)"
    }
}

/// Checks the key an endpoint presents against what it presented before.
///
/// The delegate runs on a NIO event loop and answers through a promise;
/// reading and writing the record is quick and file-local, so it is done
/// inline rather than hopped onto another queue where the promise could
/// outlive the handshake.
final class TrustOnFirstUseHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    private let endpoint: String
    private let store: KnownHostsStore
    private let log: HamasenLog

    init(endpoint: String, store: KnownHostsStore, log: HamasenLog) {
        self.endpoint = endpoint
        self.store = store
        self.log = log
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fingerprint = HostKeyFingerprint.sha256(of: hostKey)
        do {
            switch try store.verdict(forEndpoint: endpoint, fingerprint: fingerprint) {
            case .trustedOnFirstUse:
                log.notice("Recorded the host key for \(endpoint): \(fingerprint)")
                validationCompletePromise.succeed(())
            case .unchanged:
                validationCompletePromise.succeed(())
            case .changed(let recorded):
                log.error("Host key for \(endpoint) changed: expected \(recorded), got \(fingerprint)")
                validationCompletePromise.fail(
                    RemoteFileServiceError.hostKeyChanged(
                        endpoint: endpoint,
                        recorded: recorded,
                        presented: fingerprint
                    )
                )
            }
        } catch {
            validationCompletePromise.fail(
                RemoteFileServiceError.hostKeyUnverifiable(reason: error.localizedDescription)
            )
        }
    }
}

extension HostKeyPolicy {
    /// The validator Citadel connects with.
    func makeValidator(endpoint: String, log: HamasenLog) -> SSHHostKeyValidator {
        switch self {
        case .trustOnFirstUse(let store):
            return .custom(TrustOnFirstUseHostKeyValidator(endpoint: endpoint, store: store, log: log))
        case .unverifiable(let reason):
            return .custom(RefusingHostKeyValidator(reason: reason))
        case .acceptAnything:
            return .acceptAnything()
        }
    }
}

/// Refuses every key, for when the record of known keys cannot be read.
/// Connecting anyway would be the unverified connection this exists to stop.
private final class RefusingHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    private let reason: String

    init(reason: String) {
        self.reason = reason
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.fail(RemoteFileServiceError.hostKeyUnverifiable(reason: reason))
    }
}
