public import HTTPTypes
public import ProtobufWireCore

/// Why a request could not be authenticated, in the `servicecore.auth` domain.
///
/// Each code tells the client what to do next:
///
/// | Code | Status | Client should |
/// |---|---|---|
/// | `missingAccessToken` | 401 | sign in |
/// | `invalidAccessToken` | 401 | look for a newer token: retry with a higher version from storage, or wait for one to arrive (see the README's client rules); otherwise sign in |
/// | `signInRequired` | 401 | sign in: the session was revoked or expired |
/// | `invalidAuthorizationCode` | 400 | restart the sign-in flow |
/// | `insufficientScope` | 403 | ask for the scopes in `metadata["scope"]` |
/// | `accountsUnavailable` | 503 | retry later, with the same token |
public enum AuthenticationErrorCode: Int32, ServiceErrorCode {
    case missingAccessToken = 1
    case invalidAccessToken = 2
    case signInRequired = 3
    case invalidAuthorizationCode = 4
    case insufficientScope = 5
    case accountsUnavailable = 6

    public static let domain = "servicecore.auth"

    /// The code's name in the `X-Authentication-Error` header, which every
    /// authentication error carries so clients can act on it without decoding
    /// the body.
    public var headerValue: String {
        switch self {
        case .missingAccessToken: "missing_access_token"
        case .invalidAccessToken: "invalid_access_token"
        case .signInRequired: "sign_in_required"
        case .invalidAuthorizationCode: "invalid_authorization_code"
        case .insufficientScope: "insufficient_scope"
        case .accountsUnavailable: "accounts_unavailable"
        }
    }

    public var category: WireErrorCode {
        switch self {
        case .missingAccessToken, .invalidAccessToken, .signInRequired: .unauthenticated
        case .invalidAuthorizationCode: .invalidArgument
        case .insufficientScope: .permissionDenied
        case .accountsUnavailable: .unavailable
        }
    }
}

/// An authentication failure. Thrown as an `AbortError`, so it renders with
/// the right status under any error middleware, and as a protobuf
/// `ErrorDetail` under ProtobufWireCore's.
public typealias AuthenticationError = ServiceError<AuthenticationErrorCode>

extension HTTPField.Name {
    /// Names the ``AuthenticationErrorCode`` of an authentication failure.
    public static let authenticationError = HTTPField.Name("X-Authentication-Error")!
}

extension ServiceError where Code == AuthenticationErrorCode {
    public static func missingAccessToken() -> Self {
        make(.missingAccessToken, "an access token is required", headers: challenge(nil))
    }

    public static func invalidAccessToken() -> Self {
        make(.invalidAccessToken, "the access token is invalid, expired or has been replaced", headers: challenge("invalid_token"))
    }

    public static func signInRequired() -> Self {
        make(.signInRequired, "the session has ended; sign in again", headers: challenge("invalid_token"))
    }

    public static func invalidAuthorizationCode() -> Self {
        make(.invalidAuthorizationCode, "the authorization code is invalid, expired or already used")
    }

    public static func insufficientScope(_ scopes: [String]) -> Self {
        let scope = scopes.joined(separator: " ")
        var headers = HTTPFields()
        headers[.wwwAuthenticate] = #"Bearer error="insufficient_scope", scope="\#(scope)""#
        return make(.insufficientScope, "needs scope: \(scope)", metadata: ["scope": scope], headers: headers)
    }

    public static func accountsUnavailable() -> Self {
        make(.accountsUnavailable, "the accounts service is unavailable", headers: ["Retry-After": "5"].fields)
    }

    private static func make(
        _ code: AuthenticationErrorCode, _ message: String, metadata: [String: String] = [:], headers: HTTPFields = [:]
    ) -> Self {
        var headers = headers
        headers[.authenticationError] = code.headerValue
        return Self(code, message, metadata: metadata, headers: headers)
    }

    /// RFC 6750 §3.
    private static func challenge(_ error: String?) -> HTTPFields {
        var headers = HTTPFields()
        headers[.wwwAuthenticate] = error.map { #"Bearer error="\#($0)""# } ?? "Bearer"
        return headers
    }
}

private extension Dictionary where Key == String, Value == String {
    var fields: HTTPFields {
        var fields = HTTPFields()
        for (name, value) in self { fields[HTTPField.Name(name)!] = value }
        return fields
    }
}
