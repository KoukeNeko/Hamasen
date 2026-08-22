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

/// The host keys seen at each endpoint, shared by the app and the File
/// Provider extension.
///
/// It lives in the App Group beside the server list because the extension is
/// what actually connects: a record only the app could read would leave every
/// mounted connection unverified.
public struct KnownHostsStore: Sendable {
    private let fileURL: URL

    public init(appGroupIdentifier: String = SharedConstants.appGroupIdentifier) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw ServerConfigStore.StoreError.appGroupContainerUnavailable(groupIdentifier: appGroupIdentifier)
        }
        self.fileURL = containerURL.appendingPathComponent(SharedConstants.knownHostsFileName)
    }

    /// Test initializer: uses an arbitrary file location.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> KnownHosts {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return KnownHosts() }
        return try JSONDecoder().decode(KnownHosts.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ knownHosts: KnownHosts) throws {
        try JSONEncoder().encode(knownHosts).write(to: fileURL, options: .atomic)
    }

    /// Records a key for an endpoint that has none, and reports what the key
    /// means either way.
    ///
    /// Read and write are one step because they race otherwise: two
    /// connections opening at once would each decide the endpoint is unknown.
    @discardableResult
    public func verdict(forEndpoint endpoint: String, fingerprint: String) throws -> HostKeyVerdict {
        var knownHosts = try load()
        let verdict = knownHosts.verdict(forEndpoint: endpoint, fingerprint: fingerprint)
        if verdict == .trustedOnFirstUse {
            knownHosts.recordIfUnknown(fingerprint, forEndpoint: endpoint)
            try save(knownHosts)
        }
        return verdict
    }

    /// Drops what is known about an endpoint. The way back for a server that
    /// really was rebuilt.
    public func forget(endpoint: String) throws {
        var knownHosts = try load()
        knownHosts.forget(endpoint: endpoint)
        try save(knownHosts)
    }
}
