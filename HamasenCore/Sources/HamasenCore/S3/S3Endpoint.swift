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

/// Where the bucket name goes in the URL.
///
/// Amazon puts it in the hostname; R2 and MinIO want it in the path. Storing
/// the choice rather than deriving it every time lets someone override a
/// guess that turns out wrong for their provider.
public enum S3AddressingStyle: String, Sendable, Codable, CaseIterable {
    /// Virtual-hosted for Amazon's own endpoints, path for everything else.
    case automatic
    /// `https://bucket.host/key`
    case virtualHosted
    /// `https://host/bucket/key`
    case path

    public var displayName: String {
        switch self {
        case .automatic: return String(localized: "自動", bundle: .module)
        case .virtualHosted: return String(localized: "主機名稱", bundle: .module)
        case .path: return String(localized: "路徑", bundle: .module)
        }
    }
}

/// Turns a bucket and key into the request to send, and into the exact
/// strings the signature has to cover.
public struct S3Endpoint: Sendable, Equatable {
    /// Region names the signature's credential scope. Providers that have no
    /// regions accept this literal, and Amazon never uses it, so it doubles
    /// as "not an Amazon endpoint".
    public static let regionlessRegion = "auto"
    private static let amazonSuffix = ".amazonaws.com"
    private static let amazonDefaultRegion = "us-east-1"
    private static let s3Label = "s3"
    private static let dualStackLabel = "dualstack"

    public let scheme: String
    public let host: String
    /// nil uses the scheme's default. Present so a test server on a loopback
    /// port is addressable by the same code that talks to R2.
    public let port: Int?
    public let region: String
    public let addressingStyle: S3AddressingStyle

    public init(
        scheme: String = "https",
        host: String,
        port: Int? = nil,
        region: String,
        addressingStyle: S3AddressingStyle = .automatic
    ) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.region = region
        self.addressingStyle = addressingStyle
    }

    // MARK: - Addressing

    /// Plain HTTP for a loopback address, HTTPS for everything else.
    ///
    /// The signature keeps the secret off the wire either way, but the
    /// objects themselves would travel in the clear, so this is not offered
    /// as a setting. A loopback address is the one case where there is no
    /// wire: the traffic never leaves the machine, and it is what makes a
    /// server running here — MinIO, or the demo one — reachable at all.
    public static func scheme(forHost host: String) -> String {
        isLoopback(host) ? "http" : "https"
    }

    static func isLoopback(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if bare == "localhost" || bare == "::1" { return true }
        // Only an address literal counts: "127.example.com" is a valid name
        // that can resolve anywhere, and plain HTTP to it would put the
        // objects on the wire.
        var address = in_addr()
        guard inet_pton(AF_INET, bare, &address) == 1 else { return false }
        return bare.hasPrefix("127.")
    }

    /// A raw IPv6 literal needs brackets in a URL and in the Host header,
    /// and the field it is typed into does not require them.
    static func bracketed(_ host: String) -> String {
        guard host.contains(":"), !host.hasPrefix("[") else { return host }
        return "[\(host)]"
    }


    /// Amazon writes the region into its own hostnames, so a user pointing at
    /// AWS should not have to type it twice. Everything else reports
    /// `regionlessRegion`, which R2 and MinIO accept.
    public static func inferredRegion(forHost host: String) -> String {
        let lowered = host.lowercased()
        guard lowered.hasSuffix(amazonSuffix) else { return regionlessRegion }

        var labels = lowered.dropLast(amazonSuffix.count).split(separator: ".").map(String.init)
        // A virtual-hosted URL carries the bucket in front of everything else.
        while let first = labels.first, first != s3Label, !first.hasPrefix("\(s3Label)-") {
            labels.removeFirst()
            if labels.isEmpty { return amazonDefaultRegion }
        }
        guard let marker = labels.first else { return amazonDefaultRegion }

        // The legacy spelling joins the region to the label: s3-eu-west-1.
        if marker.hasPrefix("\(s3Label)-") {
            return String(marker.dropFirst(s3Label.count + 1))
        }
        var rest = labels.dropFirst()
        if rest.first == dualStackLabel { rest = rest.dropFirst() }
        // Plain s3.amazonaws.com names no region and means the original one.
        return rest.first ?? amazonDefaultRegion
    }

    /// A bucket name containing a dot cannot be virtual-hosted over TLS: the
    /// wildcard in the provider's certificate matches one label, and
    /// `my.bucket.s3.amazonaws.com` needs two. Such a bucket is addressed by
    /// path whatever the setting says, because the alternative is a
    /// certificate error the user cannot act on.
    enum ResolvedStyle: Sendable, Equatable {
        case virtualHosted
        case path
    }

    func resolvedStyle(for bucket: String) -> ResolvedStyle {
        if bucket.contains(".") && scheme == "https" { return .path }
        switch addressingStyle {
        case .virtualHosted: return .virtualHosted
        case .path: return .path
        case .automatic:
            return host.lowercased().hasSuffix(Self.amazonSuffix) ? .virtualHosted : .path
        }
    }

    /// The port a scheme implies, which never appears in a Host header.
    private static let defaultPorts = ["https": 443, "http": 80]

    /// URLSession omits the port when it is the scheme's default, so
    /// including it here would sign a header the request never carries.
    func hostHeader(for requestHost: String) -> String {
        let host = Self.bracketed(requestHost)
        guard let port, port != Self.defaultPorts[scheme] else { return host }
        return "\(host):\(port)"
    }

    // MARK: - Request construction

    /// Everything a signed request needs, derived once so the URL on the wire
    /// and the strings under the signature cannot disagree.
    public struct Address: Sendable, Equatable {
        public let url: URL
        /// The decoded path, for the signature to encode by its own rules.
        public let signingPath: String
        /// The value of the Host header, port included when it is not the
        /// scheme's default. The signature covers this, so it has to be what
        /// the URL loader will actually send.
        public let hostHeader: String
    }

    public func address(
        for object: S3ObjectKey, queryItems: [URLQueryItem] = []
    ) -> Address? {
        let signingPath: String
        let requestHost: String
        switch resolvedStyle(for: object.bucket) {
        case .virtualHosted:
            requestHost = "\(object.bucket).\(host)"
            signingPath = RemotePath.root + object.key
        case .path:
            requestHost = host
            signingPath = object.absolutePath
        }

        let hostHeader = hostHeader(for: requestHost)
        // Built from the signer's own encoder rather than URLComponents:
        // Foundation leaves characters in a path that SigV4 insists on
        // encoding, and any difference between the two is a 403.
        let query = AWSSignatureV4.canonicalQueryString(for: queryItems)
        let text = "\(scheme)://\(hostHeader)\(AWSSignatureV4.canonicalURI(for: signingPath))"
            + (query.isEmpty ? "" : "?\(query)")
        guard let url = URL(string: text) else { return nil }
        return Address(url: url, signingPath: signingPath, hostHeader: hostHeader)
    }
}
