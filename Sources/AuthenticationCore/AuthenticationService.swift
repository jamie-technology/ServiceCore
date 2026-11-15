public import Foundation
public import HTTPTypes
import Logging
public import Vapor

/// The person a request is authenticated as: `try req.account`.
public struct AuthenticatedAccount: Authenticatable, Hashable, Identifiable {
    /// The account's identifier at accounts. Stable for the life of the
    /// account, across refreshes, devices and sign-ins: key a service's own
    /// per-account data on it, never on the access token.
    public var id: String { subject }

    /// The account's identifier at accounts (the token's `sub`); the same as ``id``.
    public var subject: String
    public var scopes: Set<String>

    /// The access token the request is authenticated with: the one it sent, or
    /// the refreshed one that replaced it.
    public var accessToken: String

    /// The OAuth client acting for the person, when it's another service with a
    /// token for this service's API (RFC 8707). `nil` when the person signed in
    /// to this service itself. Record it alongside the person (in audit logs,
    /// say): the person is who acts, the client is how.
    public var client: String?

    public init(subject: String, scopes: Set<String>, accessToken: String, client: String? = nil) {
        self.subject = subject
        self.scopes = scopes
        self.accessToken = accessToken
        self.client = client
    }
}

/// Another service acting as itself, with a client-credentials token for this
/// service's API (RFC 8707): `try req.principal`, on routes that accept
/// services.
public struct AuthenticatedService: Hashable, Sendable {
    /// The service's OAuth client identifier at accounts.
    public var clientIdentifier: String
    public var scopes: Set<String>
    public var accessToken: String

    public init(clientIdentifier: String, scopes: Set<String>, accessToken: String) {
        self.clientIdentifier = clientIdentifier
        self.scopes = scopes
        self.accessToken = accessToken
    }
}

/// Whoever a request is authenticated as. A service's identity is never the
/// person's: a person acting through another service is still an
/// ``account(_:)`` (with its ``AuthenticatedAccount/client``), and only a
/// service acting as itself is a ``service(_:)``.
public enum AuthenticatedPrincipal: Authenticatable, Hashable, Sendable {
    case account(AuthenticatedAccount)
    case service(AuthenticatedService)

    /// `account:<id>` or `service:<client identifier>`: one namespace for both, so
    /// a service can never be mistaken for a person (or the other way round).
    public var subject: String {
        switch self {
        case .account(let account): "account:\(account.subject)"
        case .service(let service): "service:\(service.clientIdentifier)"
        }
    }

    public var scopes: Set<String> {
        switch self {
        case .account(let account): account.scopes
        case .service(let service): service.scopes
        }
    }
}

/// A refreshed access token for the client, and its place in the order of
/// tokens (see ``AccessTokenVersion``).
public struct UpdatedAccessToken: Sendable, Hashable {
    public var accessToken: String
    public var version: AccessTokenVersion
}

/// A successful authentication.
public struct Authentication: Sendable, Hashable {
    public var account: AuthenticatedAccount

    /// Set when the token presented had expired and was refreshed. The client
    /// must store it, unless it already holds a higher version.
    public var updated: UpdatedAccessToken?
}

/// A successful authentication that may be a service's (see
/// ``AuthenticationService/authenticatePrincipal(accessToken:)``).
public struct PrincipalAuthentication: Sendable, Hashable {
    public var principal: AuthenticatedPrincipal

    /// Set when this service's own sign-in token had expired and was refreshed.
    public var updated: UpdatedAccessToken?
}

/// A signed-in session, as a client receives it.
///
/// Send it back in ``responseHeaders``, whatever the sign-in route's body
/// looks like: the client libraries store the token from the same headers
/// that carry refreshed ones.
public struct SignIn: Sendable, Hashable {
    public var accessToken: String
    /// Store it with the token: clients keep the highest version they are given.
    public var version: AccessTokenVersion
    /// Seconds until the access token expires. The client does not need to act
    /// on it: an expired token is refreshed on its next request.
    public var expiresIn: Int64
    public var account: AuthenticatedAccount

    /// `X-Updated-Access-Token` and `X-Updated-Access-Token-Version` with this
    /// token, and `Cache-Control: no-store`. Put them on the sign-in response:
    ///
    /// ```swift
    /// return try ProtobufResponse.success(body, headers: signIn.responseHeaders)
    /// ```
    public var responseHeaders: HTTPFields {
        var headers = HTTPFields()
        headers[.updatedAccessToken] = accessToken
        headers[.updatedAccessTokenVersion] = version.description
        headers[.cacheControl] = "no-store"
        return headers
    }
}

/// How long sessions last.
public struct SessionPolicy: Sendable, Hashable {
    /// How long a session lasts without a refresh, after which the store may
    /// forget it. Match accounts' refresh-token lifetime (60 days, extended on
    /// every refresh).
    public var sessionLifetime: Duration

    public init(sessionLifetime: Duration = .seconds(60 * 24 * 60 * 60)) {
        self.sessionLifetime = sessionLifetime
    }
}

/// Signs people in through accounts and authenticates their requests,
/// refreshing expired access tokens on their behalf.
///
/// The service is a confidential OAuth client: it exchanges authorisation codes
/// and holds the refresh tokens itself (in a ``SessionStore``). Clients only
/// ever hold an access token and its ``AccessTokenVersion``.
///
/// ## Refreshing
///
/// Every request's token is checked with accounts' introspection endpoint. If
/// it is not active and is its session's current token, the session is
/// refreshed and the request goes ahead as the new token, which
/// ``AuthenticationMiddleware`` sends back with its version.
///
/// A refresh is a compare-and-set at accounts on the token's generation: from
/// the current generation it issues the next token, and from the one before it
/// returns the token already issued. So any number of requests refreshing the
/// same token, concurrently or late, all get the same successor, and none
/// invalidates a token another was just handed. There are no locks or leases.
///
/// The store then moves the session to the new generation, but only forwards:
/// a refresh whose result arrives after a later one has been recorded changes
/// nothing. Once a session has moved on, its old token finds no session and is
/// refused with `invalidAccessToken`; see the README for what clients do then.
public struct AuthenticationService: Sendable {
    public let accounts: any AccountsOAuthClient
    public let store: any SessionStore
    public let policy: SessionPolicy

    /// This service's own API's resource identifier at accounts, if it provides
    /// one (RFC 8707): tokens other services' clients got for it are accepted.
    /// `nil` accepts only tokens from this service's own sign-in.
    public let resourceIdentifier: String?

    /// Tokens for other services' APIs, per session and resource, until shortly before they expire.
    let resourceTokens = ResourceTokenCache()

    private let now: @Sendable () -> Date

    public init(
        accounts: any AccountsOAuthClient,
        store: any SessionStore,
        policy: SessionPolicy = SessionPolicy(),
        resourceIdentifier: String? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.accounts = accounts
        self.store = store
        self.policy = policy
        self.resourceIdentifier = resourceIdentifier
        self.now = now
    }

    /// Talks to accounts over HTTP with `client`. Accepts tokens for
    /// `configuration.resourceIdentifier`, if set.
    public init(
        configuration: AccountsConfiguration,
        client: any Client,
        store: any SessionStore,
        policy: SessionPolicy = SessionPolicy()
    ) {
        self.init(
            accounts: HTTPAccountsOAuthClient(configuration: configuration, client: client),
            store: store, policy: policy, resourceIdentifier: configuration.resourceIdentifier
        )
    }

    // MARK: - Signing in and out

    /// Completes a sign-in: exchanges the authorisation code accounts redirected
    /// back with, and starts a session for the tokens.
    ///
    /// Return ``SignIn/accessToken`` and ``SignIn/version`` to the client. The
    /// refresh token stays here.
    public func signIn(code: String, redirectURI: String?) async throws -> SignIn {
        let grant: TokenGrant
        do {
            grant = try await accounts.exchange(code: code, redirectURI: redirectURI)
        } catch let error as AccountsOAuthError where error.isInvalidGrant {
            throw AuthenticationError.invalidAuthorizationCode()
        } catch let error as AccountsOAuthError {
            throw Self.unavailable(error)
        }
        guard let refreshToken = grant.refreshToken else {
            // A client-credentials token: never a person's.
            throw AuthenticationError.invalidAuthorizationCode()
        }
        let generation = try Self.generation(of: grant)

        // The token response does not name the account; introspection does.
        let introspection = try await introspect(grant.accessToken)
        guard introspection.active, let subject = introspection.subject else {
            throw AuthenticationError.invalidAuthorizationCode()
        }

        let now = now()
        let session = SessionRecord(
            id: UUID(), tokenDigest: TokenDigest(token: grant.accessToken), generation: generation,
            refreshToken: refreshToken, subject: subject, scopes: grant.scopes,
            signedInAt: UInt64(now.timeIntervalSince1970 * 1000),
            expiresAt: now + policy.sessionLifetime.timeInterval
        )
        _ = try await store.replace(session.id, expected: nil, with: session)

        return SignIn(
            accessToken: grant.accessToken, version: session.version, expiresIn: grant.expiresIn,
            account: AuthenticatedAccount(subject: subject, scopes: Set(grant.scopes), accessToken: grant.accessToken)
        )
    }

    /// Forgets the session, so its refresh token is never used again. The access
    /// token itself stays valid at accounts until it expires.
    public func signOut(accessToken: String) async throws {
        while let session = try await store.session(forToken: TokenDigest(token: accessToken)) {
            if try await store.replace(session.id, expected: session, with: nil) { return }
        }
    }

    // MARK: - Authenticating

    /// Authenticates a request's access token, refreshing it if it has expired.
    ///
    /// - Throws: ``AuthenticationError``: `invalidAccessToken` for a token that is
    ///   unknown or already replaced, `signInRequired` when accounts refuses to
    ///   refresh the session, `accountsUnavailable` when it cannot be asked.
    public func authenticate(accessToken: String) async throws -> Authentication {
        let authentication = try await authenticatePrincipal(accessToken: accessToken)
        // Services acting as themselves only get in where a route asks for them.
        guard case .account(let account) = authentication.principal else {
            throw AuthenticationError.invalidAccessToken()
        }
        return Authentication(account: account, updated: authentication.updated)
    }

    /// Authenticates a request's access token as a person or a service, refreshing
    /// it first if it's this service's own sign-in token and has expired.
    ///
    /// Accounts only says a token is active to the client it was issued to, or to
    /// the service whose API it's for. So an active token is one of:
    ///
    /// | Token | Principal |
    /// |---|---|
    /// | from this service's own sign-in | ``AuthenticatedPrincipal/account(_:)``, no `client` |
    /// | for this service's API, signed in through another service | ``AuthenticatedPrincipal/account(_:)``, with that `client` |
    /// | for this service's API, another service's client credentials | ``AuthenticatedPrincipal/service(_:)`` |
    ///
    /// A token for another API, or any API when ``resourceIdentifier`` is `nil`,
    /// is refused. So is this service's own client-credentials token: it's
    /// nobody's to send.
    public func authenticatePrincipal(accessToken: String) async throws -> PrincipalAuthentication {
        guard !accessToken.isEmpty else { throw AuthenticationError.missingAccessToken() }
        let introspection = try await introspect(accessToken)
        guard introspection.active else {
            let refreshed = try await refresh(accessToken)
            return PrincipalAuthentication(principal: .account(refreshed.account), updated: refreshed.updated)
        }

        if let audience = introspection.audience {
            guard let resourceIdentifier, audience == resourceIdentifier, let client = introspection.clientIdentifier else {
                throw AuthenticationError.invalidAccessToken()
            }
            if let subject = introspection.subject {
                return PrincipalAuthentication(principal: .account(AuthenticatedAccount(
                    subject: subject, scopes: Set(introspection.scopes), accessToken: accessToken, client: client
                )))
            }
            return PrincipalAuthentication(principal: .service(AuthenticatedService(
                clientIdentifier: client, scopes: Set(introspection.scopes), accessToken: accessToken
            )))
        }

        // This service's own client: a sign-in token, or (no subject) its own
        // client-credentials token, which nobody should be sending it.
        guard let subject = introspection.subject else { throw AuthenticationError.invalidAccessToken() }
        return PrincipalAuthentication(principal: .account(AuthenticatedAccount(
            subject: subject, scopes: Set(introspection.scopes), accessToken: accessToken
        )))
    }

    /// Refreshes the session whose current token `accessToken` is.
    private func refresh(_ accessToken: String) async throws -> Authentication {
        // Unknown, signed out, or already replaced: the client may hold a newer token.
        guard let session = try await store.session(forToken: TokenDigest(token: accessToken)) else {
            throw AuthenticationError.invalidAccessToken()
        }

        let grant: TokenGrant
        do {
            grant = try await accounts.refresh(refreshToken: session.refreshToken, expectedGeneration: session.generation)
        } catch let error as AccountsOAuthError where error.isInvalidGrant {
            // Revoked, expired, or the device signed out: the session is over.
            _ = try? await store.replace(session.id, expected: session, with: nil)
            throw AuthenticationError.signInRequired()
        } catch let error as AccountsOAuthError where error.isStaleGeneration {
            // The session has moved on since we read it: a newer token exists.
            throw AuthenticationError.invalidAccessToken()
        } catch let error as AccountsOAuthError {
            throw Self.unavailable(error)
        }
        let generation = try Self.generation(of: grant)

        var successor = session
        successor.tokenDigest = TokenDigest(token: grant.accessToken)
        successor.generation = generation
        successor.refreshToken = grant.refreshToken ?? session.refreshToken
        if !grant.scopes.isEmpty { successor.scopes = grant.scopes }
        successor.expiresAt = (now() + policy.sessionLifetime.timeInterval).wholeSeconds

        // Move the session forwards, never back.
        var current: SessionRecord? = session
        while true {
            if try await store.replace(session.id, expected: current, with: successor) { break }
            current = try await store.session(id: session.id)
            guard let current else {
                // Signed out, or ended, while we refreshed.
                throw AuthenticationError.signInRequired()
            }
            if current.generation >= generation { break }    // Recorded already, or overtaken.
            successor.refreshToken = grant.refreshToken ?? current.refreshToken
        }

        return Authentication(
            account: AuthenticatedAccount(subject: successor.subject, scopes: Set(successor.scopes), accessToken: grant.accessToken),
            updated: UpdatedAccessToken(
                accessToken: grant.accessToken,
                version: AccessTokenVersion(signedInAt: session.signedInAt, generation: generation)
            )
        )
    }

    private func introspect(_ accessToken: String) async throws -> TokenIntrospection {
        do {
            return try await accounts.introspect(accessToken: accessToken)
        } catch let error as AccountsOAuthError {
            throw Self.unavailable(error)
        }
    }

    /// Generations are what make refreshing safe; an accounts that does not
    /// send them is too old to use.
    private static func generation(of grant: TokenGrant) throws -> UInt64 {
        guard let generation = grant.generation else {
            Logger.current.error("accounts sent no access_token_generation; it needs updating")
            throw AuthenticationError.accountsUnavailable()
        }
        return generation
    }

    static func unavailable(_ error: AccountsOAuthError) -> AuthenticationError {
        Logger.current.error("accounts call failed", metadata: ["error": .string(error.description)])
        // A rejection other than invalid_grant (invalid_client, say) is this
        // service's misconfiguration, not the client's problem: also a 503.
        return AuthenticationError.accountsUnavailable()
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
