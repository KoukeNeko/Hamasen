import Foundation

/// What a server's host key means, given what was seen there before.
public enum HostKeyVerdict: Equatable, Sendable {
    /// Nothing was known about this endpoint. The key is taken on trust and
    /// recorded, which is what every later connection is compared against.
    case trustedOnFirstUse
    /// The same key as last time.
    case unchanged
    /// A different key from the one recorded. This is either a server that
    /// was rebuilt or someone standing in the middle, and the two cannot be
    /// told apart from here — so it is refused and said out loud.
    case changed(recorded: String)
}

/// The host keys each endpoint has presented, keyed the way OpenSSH keys
/// them: by host and port, not by server, since two configured servers on
/// one machine share its key.
public struct KnownHosts: Equatable, Sendable, Codable {
    private var fingerprintsByEndpoint: [String: String]

    public init(fingerprintsByEndpoint: [String: String] = [:]) {
        self.fingerprintsByEndpoint = fingerprintsByEndpoint
    }

    /// How an endpoint is identified. Port included: a different service on
    /// the same machine legitimately has its own key.
    public static func endpoint(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    public func verdict(forEndpoint endpoint: String, fingerprint: String) -> HostKeyVerdict {
        guard let recorded = fingerprintsByEndpoint[endpoint] else { return .trustedOnFirstUse }
        return recorded == fingerprint ? .unchanged : .changed(recorded: recorded)
    }

    public func fingerprint(forEndpoint endpoint: String) -> String? {
        fingerprintsByEndpoint[endpoint]
    }

    /// Records a key for an endpoint that has none. A key that would replace
    /// a different one is not written here: accepting a change is the user's
    /// decision, made by forgetting the endpoint first.
    public mutating func recordIfUnknown(_ fingerprint: String, forEndpoint endpoint: String) {
        guard fingerprintsByEndpoint[endpoint] == nil else { return }
        fingerprintsByEndpoint[endpoint] = fingerprint
    }

    /// Drops what is known about an endpoint, so the next connection trusts
    /// what it finds. The way back for a server that really was rebuilt.
    public mutating func forget(endpoint: String) {
        fingerprintsByEndpoint[endpoint] = nil
    }

    public var isEmpty: Bool { fingerprintsByEndpoint.isEmpty }
}

extension ServerConfig {
    /// The endpoint this server's host key belongs to.
    public var hostKeyEndpoint: String {
        KnownHosts.endpoint(host: host, port: port)
    }
}
