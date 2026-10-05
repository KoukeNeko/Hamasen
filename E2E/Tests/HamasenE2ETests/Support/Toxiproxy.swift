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

/// Network faults between the client and a server, through toxiproxy's API.
///
/// Each proxied port in the contract passes through a named proxy; a toxic on
/// it delays, throttles, cuts or fragments that traffic until removed.
enum Toxiproxy {
    enum Toxic {
        /// Every byte held back this long.
        case latency(milliseconds: Int)
        /// Throughput capped at this many kilobytes a second.
        case bandwidth(kilobytesPerSecond: Int)
        /// The connection reset after this long — a dropped Wi-Fi link.
        case resetPeer(afterMilliseconds: Int)
        /// Data stops flowing and the connection closes after this long — a
        /// NAT entry expiring under an idle session.
        case timeout(milliseconds: Int)
        /// Writes split into small random pieces, as a congested link does.
        case slicer(averageBytes: Int)

        var type: String {
            switch self {
            case .latency: return "latency"
            case .bandwidth: return "bandwidth"
            case .resetPeer: return "reset_peer"
            case .timeout: return "timeout"
            case .slicer: return "slicer"
            }
        }

        var attributes: [String: Int] {
            switch self {
            case .latency(let milliseconds): return ["latency": milliseconds, "jitter": milliseconds / 4]
            case .bandwidth(let rate): return ["rate": rate]
            case .resetPeer(let after): return ["timeout": after]
            case .timeout(let milliseconds): return ["timeout": milliseconds]
            case .slicer(let average): return ["average_size": average, "size_variation": average / 2, "delay": 0]
            }
        }
    }

    private static let base = URL(string: "http://\(E2E.host):\(E2E.Port.toxiproxy)")!

    static func add(_ toxic: Toxic, to proxy: String, name: String, stream: String = "downstream") async throws {
        let body: [String: Any] = [
            "name": name, "type": toxic.type, "stream": stream, "toxicity": 1.0,
            "attributes": toxic.attributes,
        ]
        try await send("POST", "/proxies/\(proxy)/toxics", body: body)
    }

    static func remove(_ name: String, from proxy: String) async throws {
        try await send("DELETE", "/proxies/\(proxy)/toxics/\(name)", body: nil)
    }

    /// Disabling a proxy closes its connections and refuses new ones — the
    /// server unreachable.
    static func setEnabled(_ isEnabled: Bool, proxy: String) async throws {
        try await send("POST", "/proxies/\(proxy)", body: ["enabled": isEnabled])
    }

    /// Every proxy enabled and every toxic gone.
    static func reset() async throws {
        try await send("POST", "/reset", body: nil)
    }

    /// Runs `body` with a toxic in place, removing it however `body` ends.
    static func with<T>(
        _ toxic: Toxic, on proxy: String, stream: String = "downstream", _ body: () async throws -> T
    ) async throws -> T {
        let name = "e2e-\(UUID().uuidString.prefix(8))"
        try await add(toxic, to: proxy, name: name, stream: stream)
        do {
            let result = try await body()
            try await remove(name, from: proxy)
            return result
        } catch {
            try? await remove(name, from: proxy)
            throw error
        }
    }

    /// Runs `body` over a link slowed by `slowing`, resets the link `seconds`
    /// in, and returns whether `body` failed.
    ///
    /// The reset is added once `body` is under way. A reset_peer toxic with
    /// a timeout swallows everything sent before it fires, so one in place
    /// from the start cuts off an upload the server never saw begin.
    static func cutting(
        _ proxy: String, after seconds: Double, slowedBy slowing: [(toxic: Toxic, stream: String)],
        _ body: @escaping @Sendable () async throws -> Void
    ) async throws -> Bool {
        let names = slowing.indices.map { _ in "e2e-\(UUID().uuidString.prefix(8))" }
        let cut = "e2e-\(UUID().uuidString.prefix(8))"
        for (name, slow) in zip(names, slowing) {
            try await add(slow.toxic, to: proxy, name: name, stream: slow.stream)
        }
        let work = Task { () -> Bool in
            do {
                try await body()
                return false
            } catch {
                return true
            }
        }
        var problem: Error?
        do {
            try await Task.sleep(for: .seconds(seconds))
            try await add(.resetPeer(afterMilliseconds: 0), to: proxy, name: cut, stream: "upstream")
        } catch {
            problem = error
            work.cancel()
        }
        let failed = await work.value
        for name in names + [cut] {
            try? await remove(name, from: proxy)
        }
        if let problem { throw problem }
        return failed
    }

    private static func send(_ method: String, _ path: String, body: [String: Any]?) async throws {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw E2EError.unexpected("toxiproxy \(method) \(path): HTTP \(status) \(String(decoding: data, as: UTF8.self))")
        }
    }
}
