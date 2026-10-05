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

/// The `<Error>` document an S3-compatible service returns with a failure.
public struct S3ErrorResponse: Equatable, Sendable {
    public let code: String
    public let message: String?

    /// Returns nil rather than throwing: this runs while a failure is already
    /// being reported, and a body that will not parse is itself common —
    /// a proxy in front of the bucket answers with HTML, and HEAD carries no
    /// body at all. The caller falls back to the status code.
    public static func parse(_ data: Data) -> S3ErrorResponse? {
        let delegate = ErrorDocumentDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        guard parser.parse(), let code = delegate.code, !code.isEmpty else { return nil }
        return S3ErrorResponse(code: code, message: delegate.message)
    }

    /// Every `<Error>` element in a document.
    ///
    /// A service can answer 200 and put the failure in the body: CopyObject
    /// and CompleteMultipartUpload after they have already started sending,
    /// and DeleteObjects for each key it could not delete. The status alone
    /// reports success for all of them.
    public static func embeddedErrors(in data: Data) -> [S3ErrorResponse] {
        let delegate = EmbeddedErrorsDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        _ = parser.parse()
        return delegate.errors
    }

    // MARK: - Mapping onto the shared error type

    private static let missingCodes: Set<String> = ["NoSuchKey", "NoSuchBucket", "NotFound"]
    /// Only these mean the key pair itself is not accepted. Anything else a
    /// 403 carries — AccessDenied above all — is a policy saying no to one
    /// request, and treating it as a credential failure would put the whole
    /// domain into a sign-in state over a single denied object.
    private static let credentialCodes: Set<String> = [
        "InvalidAccessKeyId", "SignatureDoesNotMatch", "ExpiredToken", "InvalidToken",
        "InvalidSecurity",
    ]
    private static let permissionCodes: Set<String> = [
        "AccessDenied", "AllAccessDisabled", "AccountProblem",
    ]

    /// Translates a failed response into the error the rest of the app maps
    /// to a Finder message.
    ///
    /// Takes the status as well as the body because the two disagree often
    /// enough to matter: HEAD returns no body to read a code out of, and S3
    /// answers 403 rather than 404 for an object that is missing when the
    /// caller may not list the bucket — telling the user the file is gone
    /// would be a guess, and the wrong one.
    ///
    /// - Parameter forbiddenMeansCredentials: for a request that any working
    ///   key can make, where a 403 with no code can only be the key.
    ///   Everywhere else the same 403 is as likely a policy on one object.
    public static func remoteError(
        status: Int, body: Data?, operation: String, path: String,
        forbiddenMeansCredentials: Bool = false
    ) -> RemoteFileServiceError {
        remoteError(
            status: status, parsed: body.flatMap(parse), operation: operation, path: path,
            forbiddenMeansCredentials: forbiddenMeansCredentials)
    }

    public static func remoteError(
        status: Int, parsed: S3ErrorResponse?, operation: String, path: String,
        forbiddenMeansCredentials: Bool = false
    ) -> RemoteFileServiceError {
        switch (parsed?.code, status) {
        case let (code?, _) where missingCodes.contains(code):
            return .itemNotFound(path: path)
        case let (code?, _) where credentialCodes.contains(code):
            return .authenticationFailed
        case let (code?, _) where permissionCodes.contains(code):
            return .permissionDenied(operation: operation, path: path)
        case (_?, _):
            // A code the service named beats anything the status implies.
            // RequestTimeTooSkewed arrives as a 403, and reporting it as bad
            // credentials sends the user to re-enter a key that was fine
            // while the real cause — this machine's clock — goes unmentioned.
            return .operationFailed(
                operation: operation, path: path, underlying: detail(parsed, status: status))
        case (nil, 404):
            return .itemNotFound(path: path)
        case (nil, 401):
            return .authenticationFailed
        case (nil, 403):
            return forbiddenMeansCredentials
                ? .authenticationFailed
                : .permissionDenied(operation: operation, path: path)
        default:
            return .operationFailed(
                operation: operation, path: path, underlying: detail(parsed, status: status))
        }
    }

    /// The service's own code and message when it sent one, because those name
    /// causes the status code cannot — a skewed clock and a malformed request
    /// are both "400".
    private static func detail(_ parsed: S3ErrorResponse?, status: Int) -> String {
        guard let parsed, !parsed.code.isEmpty else { return "HTTP \(status)" }
        guard let message = parsed.message, !message.isEmpty else { return parsed.code }
        return "\(parsed.code): \(message)"
    }
}

private final class ErrorDocumentDelegate: NSObject, XMLParserDelegate {
    private(set) var code: String?
    private(set) var message: String?

    private var text = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName.lowercased() {
        case "code": code = value
        case "message": message = value
        default: break
        }
        text = ""
    }
}

/// Collects each `<Error>` element's own `<Code>` and `<Message>`, wherever
/// it sits in the document.
private final class EmbeddedErrorsDelegate: NSObject, XMLParserDelegate {
    private(set) var errors: [S3ErrorResponse] = []

    private var insideError = false
    private var code: String?
    private var message: String?
    private var text = ""

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String]
    ) {
        text = ""
        if elementName.lowercased() == "error" {
            insideError = true
            code = nil
            message = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName.lowercased() {
        case "code" where insideError: code = value
        case "message" where insideError: message = value
        case "error":
            // An error with no code is still an error; the empty code keeps
            // it from being read as success.
            errors.append(S3ErrorResponse(code: code ?? "", message: message))
            insideError = false
        default: break
        }
        text = ""
    }
}
