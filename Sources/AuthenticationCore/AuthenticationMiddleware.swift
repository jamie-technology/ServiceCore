public import HTTPTypes
public import ProtobufWireCore
public import Vapor

extension HTTPField.Name {
    /// Carries a refreshed access token back to the client.
    public static let updatedAccessToken = HTTPField.Name("X-Updated-Access-Token")!

    /// The refreshed token's ``AccessTokenVersion``: clients store the token
    /// only if this is higher than the version they hold.
    public static let updatedAccessTokenVersion = HTTPField.Name("X-Updated-Access-Token-Version")!
}

/// Authenticates requests with an accounts access token, refreshing it when it
/// has expired (see ``AuthenticationService``), and logs the request in as an
/// ``AuthenticatedAccount``.
///
/// ```swift
/// let authenticated = app.grouped(AuthenticationMiddleware(service: auth, requiredScopes: ["user.read"]))
/// authenticated.protobuf("v1", "notes") { (request: ListNotes, req) in
///     let account = try req.auth.require(AuthenticatedAccount.self)
///     …
/// }
/// ```
///
/// When it refreshed the token, every response carries the new one in
/// `X-Updated-Access-Token`, and its version in
/// `X-Updated-Access-Token-Version`, error responses included: a handler that throws
/// does not lose the client its session. That means errors thrown below this
/// middleware are rendered here, by ``renderError``, not by the application's
/// error middleware.
public struct AuthenticationMiddleware: Middleware {
    public let service: AuthenticationService

    /// Scopes every request must have been granted. Requests without them get
    /// `insufficientScope` (403).
    public var requiredScopes: Set<String>

    /// Lets requests without an `Authorization` header through unauthenticated,
    /// for routes that work either way. A token that is present still has to be valid.
    public var allowsAnonymous: Bool

    /// Lets other services acting as themselves in, with client-credentials
    /// tokens for this service's API (RFC 8707). Off by default: routes that
    /// turn it on read `try req.principal`, which says whether a person or a
    /// service is calling. People are let in either way, and also logged in
    /// as an ``AuthenticatedAccount`` (`try req.account`).
    public var acceptsServices: Bool


    /// Turns an error from further down into a response, when this middleware
    /// has to (see above). Defaults to a protobuf `ErrorDetail`.
    public var renderError: @Sendable (any Error, Request) async -> Response

    public init(
        service: AuthenticationService,
        requiredScopes: Set<String> = [],
        allowsAnonymous: Bool = false,
        acceptsServices: Bool = false,
        protobufConfiguration: ProtobufWireConfiguration? = nil,
        renderError: (@Sendable (any Error, Request) async -> Response)? = nil
    ) {
        self.service = service
        self.requiredScopes = requiredScopes
        self.allowsAnonymous = allowsAnonymous
        self.acceptsServices = acceptsServices
        self.renderError = renderError ?? { error, request in
            let configuration = protobufConfiguration ?? .current
            return ProtobufResponse.failure(
                error, requestID: request.requestID(configuration), configuration: configuration
            )
        }
    }

    public func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        guard let token = request.headers.bearerAuthorization?.token else {
            if allowsAnonymous, request.headers[.authorization] == nil {
                return try await next.respond(to: request)
            }
            throw AuthenticationError.missingAccessToken()
        }

        let authentication = try await service.authenticatePrincipal(accessToken: token)
        if case .service = authentication.principal, !acceptsServices {
            throw AuthenticationError.invalidAccessToken()
        }
        guard let updated = authentication.updated else {
            try checkScopes(authentication.principal)
            login(authentication.principal, on: request)
            return try await next.respond(to: request)
        }

        // From here on every outcome is a response carrying the new token.
        var response: Response
        do {
            try checkScopes(authentication.principal)
            login(authentication.principal, on: request)
            response = try await next.respond(to: request)
        } catch {
            response = await renderError(error, request)
        }
        response.headers[.updatedAccessToken] = updated.accessToken
        response.headers[.updatedAccessTokenVersion] = updated.version.description
        response.headers[.cacheControl] = "no-store"
        return response
    }

    private func checkScopes(_ principal: AuthenticatedPrincipal) throws {
        let missing = requiredScopes.subtracting(principal.scopes)
        guard missing.isEmpty else { throw AuthenticationError.insufficientScope(missing.sorted()) }
    }

    private func login(_ principal: AuthenticatedPrincipal, on request: Request) {
        request.auth.login(principal)
        if case .account(let account) = principal {
            request.auth.login(account)
        }
    }
}

extension Request {
    /// The authenticated account. Throws `unauthenticated` if the route is not
    /// behind ``AuthenticationMiddleware`` or let the request through anonymously.
    public var account: AuthenticatedAccount {
        get throws {
            guard let account = auth.get(AuthenticatedAccount.self) else {
                throw AuthenticationError.missingAccessToken()
            }
            return account
        }
    }
}

extension Request {
    /// Whoever the request is authenticated as: a person (signed in to this
    /// service, or through another service's client) or, on routes that
    /// ``AuthenticationMiddleware/acceptsServices``, a service acting as itself.
    public var principal: AuthenticatedPrincipal {
        get throws {
            guard let principal = auth.get(AuthenticatedPrincipal.self) else {
                throw AuthenticationError.missingAccessToken()
            }
            return principal
        }
    }
}
