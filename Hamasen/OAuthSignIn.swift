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

import AppKit
import HamasenCore
import Network

/// Signs in to a cloud drive in the person's own browser.
///
/// The browser is sent to the provider with a PKCE challenge, and the
/// provider sends it back to a loopback address this listens on — the flow
/// every provider here documents for desktop apps. The password is typed
/// into the provider's page, never into Hamasen.
enum OAuthSignIn {
    /// Runs one sign-in to the end: the page opens, the person signs in, the
    /// code comes back and is exchanged. Cancelling the task stops waiting.
    static func signIn(provider: OAuthProvider) async throws -> OAuthToken {
        guard let client = OAuthClient.configured(for: provider) else {
            throw OAuthError.clientNotConfigured(provider)
        }
        let listener = try LoopbackRedirectListener.start(
            preferredPort: OAuthProvider.preferredLoopbackPort,
            requiresPreferredPort: provider.requiresPreferredLoopbackPort)
        defer { listener.stop() }

        let request = OAuthAuthorizationRequest(
            provider: provider, client: client, redirectURI: provider.redirectURI(port: listener.port))
        await MainActor.run { _ = NSWorkspace.shared.open(request.url) }

        let redirect = try await listener.nextRedirect()
        let code = try request.authorizationCode(fromRedirect: redirect)
        return try await OAuthTokenEndpoint.exchange(code: code, for: request)
    }
}

/// Answers the one request the browser makes when the provider sends it
/// back, and hands its URL over.
///
/// Bound to the loopback interface only, so nothing on the network can
/// reach it, and closed as soon as the sign-in ends either way.
nonisolated final class LoopbackRedirectListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.hamasen.oauth-redirect")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var delivered: Result<URL, Error>?

    /// The port actually listened on, known once the listener is ready.
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    private init(listener: NWListener) {
        self.listener = listener
    }

    /// Listens on the preferred port, or — for a provider that accepts any
    /// loopback port — on whatever port is free when that one is taken.
    static func start(preferredPort: UInt16, requiresPreferredPort: Bool) throws -> LoopbackRedirectListener {
        do {
            return try start(on: NWEndpoint.Port(rawValue: preferredPort)!)
        } catch where !requiresPreferredPort {
            return try start(on: .any)
        }
    }

    private static func start(on port: NWEndpoint.Port) throws -> LoopbackRedirectListener {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            throw OAuthError.cannotListen(error.localizedDescription)
        }

        let instance = LoopbackRedirectListener(listener: listener)
        let ready = DispatchSemaphore(value: 0)
        let failure = LockedBox<Error?>(nil)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error), .waiting(let error):
                failure.value = error
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak instance] connection in
            instance?.handle(connection)
        }
        listener.start(queue: instance.queue)
        // Binding a local port either works at once or not at all, so the
        // wait is short.
        if ready.wait(timeout: .now() + 5) == .timedOut || failure.value != nil || instance.port == 0 {
            listener.cancel()
            throw OAuthError.cannotListen(failure.value?.localizedDescription ?? "timed out")
        }
        return instance
    }

    /// Waits for the provider's redirect. Cancelling the calling task, or
    /// closing the sign-in, ends the wait with `OAuthError.cancelled`.
    func nextRedirect() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    if let delivered {
                        continuation.resume(with: delivered)
                    } else {
                        self.continuation = continuation
                    }
                }
            }
        } onCancel: {
            finish(.failure(OAuthError.cancelled))
        }
    }

    func stop() {
        listener.cancel()
        finish(.failure(OAuthError.cancelled))
    }

    private func finish(_ result: Result<URL, Error>) {
        let waiting: CheckedContinuation<URL, Error>? = lock.withLock {
            guard delivered == nil else { return nil }
            delivered = result
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            let headerEnd = Data("\r\n\r\n".utf8)
            guard buffer.range(of: headerEnd) != nil || isComplete || error != nil else {
                // A request line longer than this is not a redirect.
                if buffer.count < 65_536 { self.receive(on: connection, buffer: buffer) }
                return
            }
            self.respond(to: buffer, on: connection)
        }
    }

    private func respond(to request: Data, on connection: NWConnection) {
        let line = String(decoding: request.prefix(while: { $0 != 0x0D && $0 != 0x0A }), as: UTF8.self)
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let url = URL(string: "http://localhost\(parts[1])"),
              url.path == "/" || url.path.isEmpty
        else {
            // The browser also asks for a favicon; that is not the redirect.
            send(status: "404 Not Found", body: "", on: connection)
            return
        }
        let name = AppInfo.displayName
        let message = String(localized: "登入完成，可以關閉這個分頁，回到 \(name)。")
        send(status: "200 OK", body: Self.page(message), on: connection)
        finish(.success(url))
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }

    private func send(status: String, body: String, on connection: NWConnection) {
        let payload = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func page(_ message: String) -> String {
        let escaped = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <title>\(escaped)</title>
        <style>body{font:17px -apple-system,system-ui;display:grid;place-items:center;height:90vh;margin:0;
        color:#1d1d1f}@media(prefers-color-scheme:dark){body{background:#1d1d1f;color:#f5f5f7}}</style>
        </head><body><p>\(escaped)</p></body></html>
        """
    }
}

/// A value shared with a callback on another queue.
nonisolated final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
