public import Foundation
import HTTPTypes
public import Vapor

/// What accounts says about an access token (RFC 7662).
public struct TokenIntrospection: Sendable, Hashable {
    /// `false` for an expired, revoked or unknown token, or one that is neither
    /// issued to this service's client nor for its API. Accounts does not say which.
    public var active: Bool

    /// The account's identifier. `nil` for a client-credentials token: this
    /// service's own, or another service's for this service's API.
    public var subject: String?

    public var scopes: [String]
    public var clientIdentifier: String?
    public var expiresAt: Date?

    /// Which access token this is under its grant (`access_token_generation`).
    public var generation: UInt64?

    /// The resource identifier of the API the token is for (`aud`, RFC 8707),
    /// when another service's client got it for this service's API rather than
    /// it being issued to this service's own client.
    public var audience: String?

    public init(
        active: Bool, subject: String? = nil, scopes: [String] = [], clientIdentifier: String? = nil,
        expiresAt: Date? = nil, generation: UInt64? = nil, audience: String? = nil
    ) {
        self.active = active
        self.subject = subject
        self.scopes = scopes
        self.clientIdentifier = clientIdentifier
        self.expiresAt = expiresAt
        self.generation = generation
        self.audience = audience
    }

    public static let inactive = TokenIntrospection(active: false)
}

/// Tokens accounts issued (RFC 6749 §5.1).
public struct TokenGrant: Sendable, Hashable {
    public var accessToken: String
    /// Seconds until the access token expires.
    public var expiresIn: Int64
    /// `nil` when accounts did not send one. Accounts does not rotate refresh
    /// tokens today, so a refresh may return the same one; store whatever comes back.
    public var refreshToken: String?
    public var scopes: [String]

    /// Which access token this is under its grant (`access_token_generation`):
    /// 0 when first issued, plus one per refresh.
    public var generation: UInt64?

    public init(accessToken: String, expiresIn: Int64, refreshToken: String?, scopes: [String], generation: UInt64?) {
        self.accessToken = accessToken
        self.expiresIn = expiresIn
        self.refreshToken = refreshToken
        self.scopes = scopes
        self.generation = generation
    }
}

/// Accounts refused or could not answer.
public enum AccountsOAuthError: Error, Sendable, CustomStringConvertible {
    /// A definitive OAuth error (RFC 6749 §5.2), e.g. `invalid_grant`: the
    /// refresh token is expired or revoked, or the device signed out. Retrying
    /// will not help.
    case rejected(code: String, description: String?)

    /// Accounts is down, unreachable, or answered with something unexpected.
    /// The same call may work later.
    case unavailable(String)

    /// Whether the grant behind the token is gone for good, so the person has
    /// to sign in again. Only `invalid_grant` means that; anything else
    /// (`invalid_client`, say) is this service's misconfiguration.
    public var isInvalidGrant: Bool {
        if case .rejected(code: "invalid_grant", _) = self { return true }
        return false
    }

    /// The refresh named a generation that is neither the token's current one
    /// nor the one before it: the caller holds an outdated token. The grant
    /// itself still stands.
    public var isStaleGeneration: Bool {
        if case .rejected(code: "stale_generation", _) = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .rejected(let code, let description): "accounts rejected the request: \(code)\(description.map { " (\($0))" } ?? "")"
        case .unavailable(let reason): "accounts unavailable: \(reason)"
        }
    }
}

/// The OAuth endpoints of accounts this library calls. ``HTTPAccountsOAuthClient``
/// is the real one; tests substitute their own.
public protocol AccountsOAuthClient: Sendable {
    /// `POST /introspect`.
    func introspect(accessToken: String) async throws -> TokenIntrospection

    /// `POST /token` with `grant_type=refresh_token`, as a compare-and-set on
    /// the access token's generation: from `expectedGeneration` accounts
    /// issues the next token, and from the generation before the current one
    /// it returns the token already issued, so repeating a refresh is harmless.
    /// Anything older is ``AccountsOAuthError/isStaleGeneration``.
    func refresh(refreshToken: String, expectedGeneration: UInt64) async throws -> TokenGrant

    /// `POST /token` with `grant_type=authorization_code`.
    func exchange(code: String, redirectURI: String?) async throws -> TokenGrant
}

/// Accounts' OAuth endpoints over HTTP, authenticating with the client's secret.
public struct HTTPAccountsOAuthClient: AccountsOAuthClient {
    public let configuration: AccountsConfiguration
    public let client: any Client

    /// How long to wait for accounts.
    public var timeout: Duration

    public init(configuration: AccountsConfiguration, client: any Client, timeout: Duration = .seconds(10)) {
        self.configuration = configuration
        self.client = client
        self.timeout = timeout
    }

    public func introspect(accessToken: String) async throws -> TokenIntrospection {
        let response: IntrospectionBody = try await post("introspect", [
            ("token", accessToken), ("token_type_hint", "access_token"),
        ])
        guard response.active else { return .inactive }
        return TokenIntrospection(
            active: true,
            subject: response.sub,
            scopes: response.scope.map(Self.scopes) ?? [],
            clientIdentifier: response.client_id,
            expiresAt: response.exp.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            generation: response.access_token_generation,
            audience: response.aud
        )
    }

    public func refresh(refreshToken: String, expectedGeneration: UInt64) async throws -> TokenGrant {
        try await grant([
            ("grant_type", "refresh_token"), ("refresh_token", refreshToken),
            ("expected_generation", String(expectedGeneration)),
        ])
    }

    public func exchange(code: String, redirectURI: String?) async throws -> TokenGrant {
        var form = [("grant_type", "authorization_code"), ("code", code)]
        if let redirectURI { form.append(("redirect_uri", redirectURI)) }
        return try await grant(form)
    }

    private func grant(_ form: [(String, String)]) async throws -> TokenGrant {
        let response: TokenBody = try await post("token", form)
        return TokenGrant(
            accessToken: response.access_token,
            expiresIn: response.expires_in,
            refreshToken: response.refresh_token,
            scopes: response.scope.map(Self.scopes) ?? [],
            generation: response.access_token_generation
        )
    }

    private func post<Body: Decodable>(_ path: String, _ form: [(String, String)]) async throws -> Body {
        let fields = form + [
            ("client_id", configuration.clientIdentifier), ("client_secret", configuration.clientSecret),
        ]
        var request = ClientRequest(
            method: .post, url: URI(string: configuration.apiURL.appending(path: path).absoluteString),
            timeout: timeout
        )
        request.headers[.contentType] = "application/x-www-form-urlencoded"
        request.headers[.accept] = "application/json"
        request.body = .init(data: Data(FormEncoding.encode(fields).utf8))

        let response: ClientResponse
        do {
            response = try await client.send(request)
        } catch {
            throw AccountsOAuthError.unavailable("\(path): \(error)")
        }
        let data = (try? await response.body.data(max: .default)) ?? Data()

        guard (200..<300).contains(response.status.code) else {
            // 4xx with an OAuth error body is a decision; anything else (5xx, a
            // proxy's error page) is accounts not being able to decide.
            if (400..<500).contains(response.status.code),
               let error = try? JSONDecoder().decode(ErrorBody.self, from: data) {
                throw AccountsOAuthError.rejected(code: error.error, description: error.error_description)
            }
            throw AccountsOAuthError.unavailable("\(path) answered \(response.status.code)")
        }
        do {
            return try JSONDecoder().decode(Body.self, from: data)
        } catch {
            throw AccountsOAuthError.unavailable("\(path) answered with an unreadable body")
        }
    }

    private static func scopes(_ scope: String) -> [String] {
        scope.split(separator: " ").map(String.init)
    }

    // Accounts' JSON, named as it is on the wire.
    // swiftlint:disable identifier_name
    private struct TokenBody: Decodable {
        let access_token: String
        let expires_in: Int64
        let refresh_token: String?
        let scope: String?
        let access_token_generation: UInt64?
    }

    private struct IntrospectionBody: Decodable {
        let active: Bool
        let scope: String?
        let client_id: String?
        let exp: Int64?
        let sub: String?
        let access_token_generation: UInt64?
        let aud: String?
    }

    private struct ErrorBody: Decodable {
        let error: String
        let error_description: String?
    }
    // swiftlint:enable identifier_name
}

/// `application/x-www-form-urlencoded`, as OAuth requires (RFC 6749 Appendix B).
enum FormEncoding {
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func encode(_ fields: [(String, String)]) -> String {
        fields.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    static func escape(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }
}
