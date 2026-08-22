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

import Foundation
import NIOCore
import NIOSSL

/// Whether an FTP session is protected, and how.
public enum FTPTLSMode: Sendable {
    /// Everything in the clear, including the password. What plain FTP is.
    case none
    /// The connection starts in the clear and is upgraded by `AUTH TLS`
    /// before anyone logs in, then `PROT P` puts the transfers inside TLS
    /// too. This is what "FTPS" means in practice; the other reading —
    /// TLS from the first byte on port 990 — was never standardised and is
    /// rare enough to leave out.
    case explicit
}

/// Builds the TLS handlers an FTPS session needs.
enum FTPTLS {
    static func makeContext() throws -> NIOSSLContext {
        try NIOSSLContext(configuration: .makeClientConfiguration())
    }

    /// - Parameter host: sent as the server name, unless it is an address —
    ///   TLS has no way to name one, and passing it would fail the handshake
    ///   rather than skip the check.
    static func makeHandler(context: NIOSSLContext, host: String) throws -> NIOSSLClientHandler {
        try NIOSSLClientHandler(context: context, serverHostname: isAddress(host) ? nil : host)
    }

    private static func isAddress(_ host: String) -> Bool {
        var address = in_addr()
        if inet_pton(AF_INET, host, &address) == 1 { return true }
        var address6 = in6_addr()
        return inet_pton(AF_INET6, host, &address6) == 1
    }
}
