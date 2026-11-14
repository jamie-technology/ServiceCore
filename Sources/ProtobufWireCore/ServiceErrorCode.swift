public import HTTPTypes
public import SwiftProtobuf

/// A set of error codes a service can fail with.
///
/// This is how the shared error format stays extensible. ``WireErrorCode`` is
/// the fixed list of standard categories every client understands. A service
/// that needs finer distinctions defines its own codes, in a `.proto` enum or
/// a Swift enum, and conforms them here, mapping each one onto a standard
/// category. On the wire the category goes in `ErrorDetail.code` and the
/// service's own code in `ErrorDetail.domain` and `ErrorDetail.reason`, so a
/// client that only knows the standard categories still knows what to do.
///
/// A protobuf enum conforms with a domain and a category mapping; the reason
/// code and decoding come from its raw value:
///
/// ```swift
/// extension Aegis_V1_ErrorCode: ServiceErrorCode {
///     public static let domain = "aegis.v1"
///
///     public var category: WireErrorCode {
///         switch self {
///         case .zoneNotFound, .unknownItem: .notFound
///         case .serverRecordChanged: .conflict
///         default: .invalidArgument
///         }
///     }
///
///     // Optional: anything the category's default does not capture.
///     public var status: HTTPResponse.Status {
///         self == .changeTokenExpired ? .gone : category.status
///     }
/// }
/// ```
///
/// A Swift enum backed by `Int32` conforms the same way.
public protocol ServiceErrorCode: Sendable, Hashable {
    /// Names this set of codes on the wire, e.g. `"aegis.v1"`. Use the
    /// service's protobuf package so two services' codes cannot be confused.
    /// Empty only for ``WireErrorCode`` itself.
    static var domain: String { get }

    /// This code's number within ``domain``. Must be stable: clients match on it.
    var reasonCode: Int32 { get }

    /// The standard category this code refines.
    var category: WireErrorCode { get }

    /// The HTTP status to answer with. Defaults to the category's.
    var status: HTTPResponse.Status { get }

    /// Whether the same request, unchanged, could succeed later. Defaults to
    /// the category's.
    var isRetryable: Bool { get }

    /// The code with this number, if this set has one.
    init?(reasonCode: Int32)
}

extension ServiceErrorCode {
    public var status: HTTPResponse.Status { category.status }
    public var isRetryable: Bool { category.isRetryable }
}

extension ServiceErrorCode where Self: SwiftProtobuf.Enum {
    public var reasonCode: Int32 { Int32(truncatingIfNeeded: rawValue) }

    public init?(reasonCode: Int32) {
        self.init(rawValue: Int(reasonCode))
    }
}

extension ServiceErrorCode where Self: RawRepresentable, RawValue == Int32 {
    public var reasonCode: Int32 { rawValue }

    public init?(reasonCode: Int32) {
        self.init(rawValue: reasonCode)
    }
}

extension WireErrorCode: ServiceErrorCode {
    /// The standard categories have no domain: they are what `ErrorDetail.code`
    /// carries directly.
    public static var domain: String { "" }

    public var category: WireErrorCode { self }

    public var status: HTTPResponse.Status {
        switch self {
        case .invalidArgument: .badRequest
        case .unauthenticated: .unauthorized
        case .permissionDenied: .forbidden
        case .notFound: .notFound
        case .alreadyExists, .conflict: .conflict
        case .preconditionFailed, .leaseExpired: .preconditionFailed
        case .resourceExhausted: .tooManyRequests
        // No standard status for a request the client gave up on; 499 is the
        // de facto one (nginx, gRPC gateways).
        case .cancelled: HTTPResponse.Status(code: 499, reasonPhrase: "Client Closed Request")
        case .unavailable: .serviceUnavailable
        case .unimplemented: .notImplemented
        case .internal, .unspecified, .UNRECOGNIZED: .internalServerError
        }
    }

    /// A conflict is *not* retryable: the caller has to re-read and rebase,
    /// and retrying blindly would just lose again.
    public var isRetryable: Bool {
        switch self {
        case .resourceExhausted, .unavailable, .internal: true
        default: false
        }
    }

    /// The category a bare HTTP status implies, for errors that carry nothing
    /// more specific (Vapor's `Abort`, a body-size limit).
    public init(status: HTTPResponse.Status) {
        switch status.code {
        case 400, 413, 414, 415, 422, 431: self = .invalidArgument
        case 401: self = .unauthenticated
        case 403: self = .permissionDenied
        case 404, 410: self = .notFound
        case 409: self = .conflict
        case 412, 428: self = .preconditionFailed
        case 429: self = .resourceExhausted
        case 499: self = .cancelled
        case 501: self = .unimplemented
        case 502, 503, 504: self = .unavailable
        default: self = .internal
        }
    }
}

extension WireErrorDetail {
    /// The service-specific code this error carries, if it comes from `C`'s
    /// domain. For ``WireErrorCode`` this is the standard category.
    ///
    /// ```swift
    /// if detail.code(as: Aegis_V1_ErrorCode.self) == .serverRecordChanged { … }
    /// ```
    public func code<C: ServiceErrorCode>(as type: C.Type) -> C? {
        if C.domain.isEmpty {
            return C(reasonCode: Int32(truncatingIfNeeded: code.rawValue))
        }
        guard domain == C.domain else { return nil }
        return C(reasonCode: reason)
    }
}
