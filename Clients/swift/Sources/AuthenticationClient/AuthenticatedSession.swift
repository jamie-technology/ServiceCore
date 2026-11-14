import Foundation

/// Response headers and values ServiceCore's `AuthenticationMiddleware` uses.
public enum AuthenticationHeaders {
    public static let updatedAccessToken = "X-Updated-Access-Token"
    public static let updatedAccessTokenVersion = "X-Updated-Access-Token-Version"
    public static let authenticationError = "X-Authentication-Error"
}

/// The person must sign in (again).
public enum AuthenticationClientError: Error, Sendable, Equatable {
    /// No token is stored.
    case notSignedIn
    /// The session has ended, or no newer token turned up for an outdated one.
    case signInRequired
    /// A successful sign-in response carried no `X-Updated-Access-Token`.
    case missingToken
}

/// Sends requests to a ServiceCore service with the stored access token,
/// following its refresh protocol:
///
/// - Any response carrying `X-Updated-Access-Token` updates storage, unless a
///   higher version is already stored.
/// - On `invalid_access_token` (the token was replaced by a refresh), it retries
///   with a newer stored token. If there is none yet, another request (in this
///   process or another) may be about to bring it back, so it waits for one,
///   for up to ``newTokenTimeout``, and only then gives up.
/// - On `sign_in_required` it forgets the token and throws
///   ``AuthenticationClientError/signInRequired``.
///
/// Use one storage for every process that shares the token. Requests with an
/// `httpBodyStream` cannot be resent, so they are never retried: send bodies
/// as `httpBody`.
public struct AuthenticatedSession: Sendable {
    public let storage: any AccessTokenStorage
    public let urlSession: URLSession

    /// How long to wait for another request to bring back a refreshed token.
    /// Any request sent with the old token finishes, or times out, within the
    /// request timeout, so that is the default.
    public var newTokenTimeout: Duration

    public init(storage: any AccessTokenStorage, urlSession: URLSession = .shared, newTokenTimeout: Duration? = nil) {
        self.storage = storage
        self.urlSession = urlSession
        self.newTokenTimeout = newTokenTimeout ?? .seconds(urlSession.configuration.timeoutIntervalForRequest)
    }

    /// Sends `request` with the stored token, retrying as above.
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard var token = try storage.current() else { throw AuthenticationClientError.notSignedIn }
        let replayable = request.httpBodyStream == nil

        for _ in 0..<5 {
            var authorized = request
            authorized.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await urlSession.data(for: authorized)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            try absorb(http)

            switch http.value(forHTTPHeaderField: AuthenticationHeaders.authenticationError) {
            case "invalid_access_token":
                // Every retry needs a strictly newer token, so this ends.
                guard replayable, let newer = try await newer(than: token.version) else {
                    try storage.remove(upTo: token.version)
                    throw AuthenticationClientError.signInRequired
                }
                token = newer
            case "sign_in_required", "missing_access_token":
                try storage.remove(upTo: token.version)
                throw AuthenticationClientError.signInRequired
            default:
                return (data, http)
            }
        }
        throw AuthenticationClientError.signInRequired
    }

    /// Calls the service's sign-in endpoint (whatever its path and body)
    /// without a token, and stores the token it returns in
    /// `X-Updated-Access-Token` and `X-Updated-Access-Token-Version`. Returns
    /// the response, for whatever else its body says.
    ///
    /// A failed sign-in (any non-2xx) is returned as it is; a successful one
    /// without the headers throws ``AuthenticationClientError/missingToken``.
    public func signIn(with request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else { return (data, http) }
        guard http.value(forHTTPHeaderField: AuthenticationHeaders.updatedAccessToken) != nil else {
            throw AuthenticationClientError.missingToken
        }
        try absorb(http)
        return (data, http)
    }

    /// Signs out: sends `request` (the service's sign-out endpoint, so it
    /// forgets the refresh token) if given, then forgets the token here,
    /// whatever the request's outcome.
    public func signOut(with request: URLRequest? = nil) async throws {
        if let request {
            _ = try? await data(for: request)
        }
        try storage.removeAll()
    }

    /// Stores a token a response carried.
    func absorb(_ response: HTTPURLResponse) throws {
        guard let accessToken = response.value(forHTTPHeaderField: AuthenticationHeaders.updatedAccessToken),
              let version = response.value(forHTTPHeaderField: AuthenticationHeaders.updatedAccessTokenVersion)
                .flatMap(AccessTokenVersion.init) else { return }
        try storage.offer(StoredAccessToken(accessToken: accessToken, version: version))
    }

    private func newer(than version: AccessTokenVersion) async throws -> StoredAccessToken? {
        if let current = try storage.current(), current.version > version { return current }
        return try await storage.waitForNewer(than: version, timeout: newTokenTimeout)
    }
}
