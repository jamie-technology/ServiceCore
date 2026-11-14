public import HTTPTypes
public import SwiftProtobuf
public import Vapor

/// An error a service sends to its client as a protobuf body.
///
/// ``ServiceError`` is the usual one. Conform your own type when a service
/// already has its own wire error message (Aegis's `Error`, which carries the
/// server's copy of a record on conflict): the error-handling helpers send
/// whatever ``body`` returns, with ``status``.
public protocol ProtobufErrorConvertible: Error {
    /// The HTTP status to answer with.
    var status: HTTPResponse.Status { get }

    /// The response body.
    var body: any SwiftProtobuf.Message { get }

    /// Extra response headers, e.g. `Retry-After`.
    var responseHeaders: HTTPFields { get }

    /// What to log about this error. Defaults to `String(describing: self)`.
    var logDescription: String { get }
}

extension ProtobufErrorConvertible {
    public var responseHeaders: HTTPFields { [:] }
    public var logDescription: String { String(describing: self) }
}

/// A structured failure: a code, a message for a human, and optional metadata.
///
/// Structured so a client can branch: "conflict, rebase and retry" and "you
/// are not allowed to do this" need different responses, and an HTTP status
/// alone does not separate them well enough.
///
/// Generic over the code set, so a service throws errors in its own codes
/// (see ``ServiceErrorCode``) and they still arrive as a standard
/// `ErrorDetail`. For the standard categories alone, use ``StandardError``:
///
/// ```swift
/// throw StandardError.notFound("no such zone")
/// throw ServiceError(Aegis_V1_ErrorCode.zoneNotFound, "Zone 'x' does not exist")
/// ```
public struct ServiceError<Code: ServiceErrorCode>: ProtobufErrorConvertible, AbortError, Sendable, CustomStringConvertible {
    public var code: Code
    public var message: String
    public var metadata: [String: String]
    public var isRetryable: Bool
    public var headers: HTTPFields

    /// - Parameters:
    ///   - retryable: Overrides whether the client may retry; defaults to the
    ///     code's.
    ///   - headers: Extra response headers.
    public init(
        _ code: Code,
        _ message: String,
        metadata: [String: String] = [:],
        retryable: Bool? = nil,
        headers: HTTPFields = [:]
    ) {
        self.code = code
        self.message = message
        self.metadata = metadata
        self.isRetryable = retryable ?? code.isRetryable
        self.headers = headers
    }

    public var status: HTTPResponse.Status { code.status }
    public var reason: String { message }
    public var responseHeaders: HTTPFields { headers }

    /// The error as it goes on the wire.
    public var detail: WireErrorDetail {
        var detail = WireErrorDetail()
        detail.code = code.category
        detail.message = message
        detail.retryable = isRetryable
        detail.metadata = metadata
        if !Code.domain.isEmpty {
            detail.domain = Code.domain
            detail.reason = code.reasonCode
        }
        return detail
    }

    public var body: any SwiftProtobuf.Message { detail }

    public var description: String {
        let domain = Code.domain.isEmpty ? "" : "\(Code.domain)/\(code.reasonCode) "
        let extra = metadata.isEmpty
            ? ""
            : " (" + metadata.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
                .joined(separator: ", ") + ")"
        return "\(domain)\(code.category): \(message)\(extra)"
    }
}

/// An error in the standard categories only.
public typealias StandardError = ServiceError<WireErrorCode>

extension ServiceError where Code == WireErrorCode {
    public static func invalidArgument(_ message: String) -> Self { Self(.invalidArgument, message) }
    public static func unauthenticated(_ message: String) -> Self { Self(.unauthenticated, message) }
    public static func permissionDenied(_ message: String) -> Self { Self(.permissionDenied, message) }
    public static func notFound(_ message: String) -> Self { Self(.notFound, message) }
    public static func alreadyExists(_ message: String) -> Self { Self(.alreadyExists, message) }

    /// A compare-and-set lost. `expected` and `actual` go in the metadata so a
    /// client can rebase without another round trip.
    public static func conflict(_ message: String, expected: String? = nil, actual: String? = nil) -> Self {
        var metadata: [String: String] = [:]
        if let expected { metadata["expected"] = expected }
        if let actual { metadata["actual"] = actual }
        return Self(.conflict, message, metadata: metadata)
    }

    public static func preconditionFailed(_ message: String) -> Self { Self(.preconditionFailed, message) }
    public static func leaseExpired(_ message: String) -> Self { Self(.leaseExpired, message) }

    /// - Parameter retryAfter: Seconds the client should wait, sent as
    ///   `Retry-After`.
    public static func resourceExhausted(_ message: String, retryAfter: Int? = nil) -> Self {
        Self(.resourceExhausted, message, headers: retryAfterHeaders(retryAfter))
    }

    public static func unavailable(_ message: String, retryAfter: Int? = nil) -> Self {
        Self(.unavailable, message, headers: retryAfterHeaders(retryAfter))
    }

    public static func cancelled(_ message: String) -> Self { Self(.cancelled, message) }
    public static func unimplemented(_ message: String) -> Self { Self(.unimplemented, message) }

    /// The message reaches the client, so keep it free of internals.
    public static func internalError(_ message: String) -> Self { Self(.internal, message) }

    private static func retryAfterHeaders(_ seconds: Int?) -> HTTPFields {
        guard let seconds else { return [:] }
        var headers = HTTPFields()
        headers[.retryAfter] = String(max(0, seconds))
        return headers
    }
}
