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

/// The HTTP every cloud drive client shares: a bearer token on each request,
/// one renewal when it is rejected, and patience when the provider says to
/// slow down.
///
/// What a status code means beyond that is each provider's own business, so
/// responses come back unjudged and the caller maps them.
final class CloudHTTPClient: Sendable {
    /// What a request is sent with.
    enum Body: Sendable {
        case none
        case data(Data)
        case file(URL)
    }

    private static let maximumRetries = 4

    let urlSession: URLSession
    /// Whether the session was made here, and so is released here. One
    /// handed in by a caller is the caller's to invalidate.
    private let ownsSession: Bool
    private let auth: OAuthSession
    /// A provider-specific way of saying "later": Google answers some rate
    /// limits with a 403 whose reason says so.
    private let isThrottled: @Sendable (Int, Data) -> Bool

    init(
        auth: OAuthSession, urlSession: URLSession, ownsSession: Bool,
        isThrottled: @escaping @Sendable (Int, Data) -> Bool = { _, _ in false }
    ) {
        self.auth = auth
        self.urlSession = urlSession
        self.ownsSession = ownsSession
        self.isThrottled = isThrottled
    }

    /// A session that is never invalidated keeps its connection pool for the
    /// life of the process, and the extension makes a new client every time
    /// it reconnects. Nothing can start a request on this one once the client
    /// is gone, so invalidating it here cannot race a new task.
    deinit {
        if ownsSession { urlSession.finishTasksAndInvalidate() }
    }

    /// A session that keeps nothing between requests — no cookies, no cache,
    /// no credentials — and gives up on a silent server after the
    /// connection timeout the user chose.
    static func makeSession(connectTimeoutSeconds: Int) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = TimeInterval(max(connectTimeoutSeconds, 5))
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    /// Sends a request and returns its body.
    ///
    /// - Parameter authorized: false for the pre-signed URLs some providers
    ///   hand out for transfers, which must not receive the account's token.
    func send(
        _ request: URLRequest, body: Body = .none, authorized: Bool = true,
        progress: TransferProgress? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        try await perform(request, authorized: authorized) { request in
            let delegate = progress.map { TransferProgressDelegate(progress: $0) }
            switch body {
            case .none:
                return try await self.urlSession.data(for: request, delegate: delegate)
            case .data(let data):
                return try await self.urlSession.upload(for: request, from: data, delegate: delegate)
            case .file(let url):
                return try await self.urlSession.upload(for: request, fromFile: url, delegate: delegate)
            }
        }
    }

    /// Downloads a response body to a file, returning the response so the
    /// caller can judge it. On failure the body is read back as data, since
    /// an error explanation is small and worth having.
    func download(
        _ request: URLRequest, to localURL: URL, authorized: Bool = true,
        progress: TransferProgress?
    ) async throws -> (Data, HTTPURLResponse) {
        try await perform(request, authorized: authorized) { request in
            let delegate = progress.map { TransferProgressDelegate(progress: $0) }
            let (temporaryURL, response) = try await self.urlSession.download(for: request, delegate: delegate)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else {
                return ((try? Data(contentsOf: temporaryURL)) ?? Data(), response)
            }
            if FileManager.default.fileExists(atPath: localURL.path) {
                try FileManager.default.removeItem(at: localURL)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: localURL)
            return (Data(), response)
        }
    }

    private func perform(
        _ original: URLRequest,
        authorized: Bool,
        attempt send: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> (Data, HTTPURLResponse) {
        var token = authorized ? try await auth.accessToken() : nil
        var hasRenewed = false
        var retries = 0

        while true {
            try Task.checkCancellation()
            var request = original
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

            let data: Data
            let response: HTTPURLResponse
            do {
                let (body, urlResponse) = try await send(request)
                guard let http = urlResponse as? HTTPURLResponse else {
                    throw RemoteFileServiceError.connectionFailed(underlying: "not an HTTP response")
                }
                (data, response) = (body, http)
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                if HTTPTransfer.isTransportFailure(error.code) {
                    throw HTTPTransfer.connectionFailure(error)
                }
                throw error
            }

            if response.statusCode == 401, let rejected = token, !hasRenewed {
                hasRenewed = true
                token = try await auth.accessToken(replacing: rejected)
                continue
            }
            if response.statusCode == 401, authorized {
                throw RemoteFileServiceError.authenticationFailed
            }
            // Every provider here answers an overloaded or rate-limited
            // account with one of these.
            let mayRetry = HTTPTransfer.serviceFailureStatuses.contains(response.statusCode)
                || response.statusCode == HTTPTransfer.tooManyRequestsStatus
                || isThrottled(response.statusCode, data)
            if mayRetry, retries < Self.maximumRetries,
               let wait = HTTPTransfer.retryDelay(after: response, attempt: retries) {
                retries += 1
                try await Task.sleep(for: .seconds(wait))
                continue
            }
            return (data, response)
        }
    }
}

/// JSON helpers the cloud clients share.
enum CloudJSON {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func encode(_ object: [String: Any]) -> Data {
        // Every value passed here is a string, number, bool or nested
        // dictionary of them, which JSONSerialization always accepts.
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// Dates as the providers write them: ISO 8601, with or without
    /// fractional seconds.
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = precise.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber: return number.int64Value
        case let text as String: return Int64(text)
        default: return nil
        }
    }
}

extension URLRequest {
    /// A request with a method and, for JSON bodies, the content type set.
    static func cloud(_ url: URL, method: String = "GET", json: Bool = false) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if json { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
}

/// Mount-relative paths for the cloud drives, which all address items under
/// the folder the connection was set to as their root.
enum CloudPath {
    /// The path on the provider, given one relative to the mount.
    static func absolute(_ mountRelative: String, base: String) -> String {
        RemotePath.resolve(mountRelative, against: base)
    }

    /// The path relative to the mount, given one on the provider, or nil
    /// when it lies outside the mounted folder.
    static func mountRelative(_ absolute: String, base: String) -> String? {
        let base = RemotePath.withoutTrailingSeparator(base)
        if base == RemotePath.root { return absolute }
        if absolute.caseInsensitiveCompare(base) == .orderedSame { return RemotePath.root }
        let prefix = base + RemotePath.separator
        guard absolute.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        return RemotePath.separator + absolute.dropFirst(prefix.count)
    }
}
