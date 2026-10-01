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

/// What the WebDAV and S3 clients share because both are plain HTTP over
/// URLSession: how an ETag is compared, which URLSession failures mean the
/// server could not be reached, and how bytes moved are reported.
enum HTTPTransfer {
    /// The ETag with its quoting and weak marker removed.
    ///
    /// A listing and a single-item lookup often spell one ETag differently —
    /// S3 quotes it in the listing XML and in the HEAD header alike, WebDAV
    /// servers vary between `"abc"`, `W/"abc"` and bare `abc` — and a version
    /// token that differs by spelling makes the system re-download a file
    /// that never changed.
    ///
    /// A weak tag (`W/"abc"`) is dropped rather than unwrapped: HTTP lets it
    /// stay the same across representations whose bytes differ, and both
    /// users here — the content version and the range cache's validator —
    /// need a tag that changes when a byte does. Without one they fall back
    /// to size and modification time.
    static func normalizedETag(_ raw: String?) -> String? {
        guard var tag = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if tag.hasPrefix("W/") { return nil }
        if tag.count >= 2, tag.hasPrefix("\""), tag.hasSuffix("\"") {
            tag = String(tag.dropFirst().dropLast())
        }
        return tag.isEmpty ? nil : tag
    }

    /// Failures where the request never got an answer: the server, the
    /// network or the TLS handshake, as opposed to a response saying no.
    static func isTransportFailure(_ code: URLError.Code) -> Bool {
        switch code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut,
             .networkConnectionLost, .notConnectedToInternet, .dataNotAllowed,
             .internationalRoamingOff, .secureConnectionFailed,
             .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return true
        default:
            return false
        }
    }

    /// A transport failure as the connection failure it is. The system's
    /// text for a refused connection says only what the error's own does,
    /// and quoted after it would read the same sentence twice.
    static func connectionFailure(_ error: URLError) -> RemoteFileServiceError {
        .connectionFailed(underlying: error.code == .cannotConnectToHost ? "" : error.localizedDescription)
    }
}

/// Reports upload and download progress for one URLSession task.
///
/// The async `upload` and `download` calls accept a per-task delegate, which
/// is the only way to see bytes move while the call is suspended. A task
/// delegate takes over from the session's, so redirect handling is forwarded
/// to the session delegate's instead of being lost.
final class TransferProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: TransferProgress
    private let redirectHandler: URLSessionTaskDelegate?
    private var receivedObservation: NSKeyValueObservation?

    init(redirectHandler: URLSessionTaskDelegate? = nil, progress: @escaping TransferProgress) {
        self.redirectHandler = redirectHandler
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        progress(totalBytesSent)
    }

    /// A task delegate does not receive `didWriteData` for the async download
    /// call, so the received count is observed on the task instead.
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        guard task is URLSessionDownloadTask else { return }
        receivedObservation = task.observe(\.countOfBytesReceived) { [progress] task, _ in
            progress(task.countOfBytesReceived)
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let redirectHandler else {
            completionHandler(request)
            return
        }
        redirectHandler.urlSession?(
            session, task: task, willPerformHTTPRedirection: response, newRequest: request,
            completionHandler: completionHandler)
    }
}
