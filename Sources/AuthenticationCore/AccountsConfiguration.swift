public import Configuration
public import Foundation

/// How this service reaches the accounts service, and who it is to it.
///
/// A service is an OAuth client of accounts: it is registered there (Services →
/// OAuth) with a client identifier, a secret and its redirect URIs.
public struct AccountsConfiguration: Sendable, Hashable {
    /// This service's OAuth client identifier.
    public var clientIdentifier: String

    /// This service's OAuth client secret. Never sent anywhere but accounts' API.
    public var clientSecret: String

    /// Where people sign in and approve this service: accounts' web frontend,
    /// which serves `/authorize`.
    public var frontendURL: URL

    /// Accounts' API, which serves `/token` and `/introspect`.
    public var apiURL: URL

    /// This service's own API's resource identifier, as registered at accounts
    /// (Services → API), if other services call it (RFC 8707). Their tokens for
    /// it are accepted; see ``AuthenticationService/authenticatePrincipal(accessToken:)``.
    public var resourceIdentifier: String?

    public init(clientIdentifier: String, clientSecret: String, frontendURL: URL, apiURL: URL, resourceIdentifier: String? = nil) {
        self.clientIdentifier = clientIdentifier
        self.clientSecret = clientSecret
        self.frontendURL = frontendURL
        self.apiURL = apiURL
        self.resourceIdentifier = resourceIdentifier
    }

    /// Reads, from `config`:
    ///
    /// | Key | Environment |
    /// |---|---|
    /// | `accounts.client.identifier` | `ACCOUNTS_CLIENT_IDENTIFIER` |
    /// | `accounts.client.secret` (secret) | `ACCOUNTS_CLIENT_SECRET` |
    /// | `accounts.frontend.url` | `ACCOUNTS_FRONTEND_URL` |
    /// | `accounts.api.url` | `ACCOUNTS_API_URL` |
    /// | `accounts.resource.identifier` (optional) | `ACCOUNTS_RESOURCE_IDENTIFIER` |
    ///
    /// - Parameter scope: The key prefix, if not `accounts`.
    public init(config: ConfigReader, scope: String = "accounts") throws {
        let reader = config.scoped(to: ConfigKey(scope))
        self.init(
            clientIdentifier: try reader.requiredString(forKey: "client.identifier"),
            clientSecret: try reader.requiredString(forKey: "client.secret", isSecret: true),
            frontendURL: try Self.url(reader, "frontend.url", scope: scope),
            apiURL: try Self.url(reader, "api.url", scope: scope),
            resourceIdentifier: reader.string(forKey: "resource.identifier")
        )
    }

    private static func url(_ reader: ConfigReader, _ key: String, scope: String) throws -> URL {
        let string = try reader.requiredString(forKey: ConfigKey(key))
        guard let url = URL(string: string), url.scheme == "https" || url.scheme == "http", url.host() != nil else {
            throw AccountsConfigurationError.invalidURL(key: "\(scope).\(key)", value: string)
        }
        return url
    }

    /// The page to send someone to so they sign in and approve this service
    /// (the authorisation-code flow, RFC 6749 §4.1). Accounts redirects them to
    /// `redirectURI` with `code` and `state`; hand the code to
    /// ``AuthenticationService/signIn(code:redirectURI:)``.
    ///
    /// - Parameters:
    ///   - redirectURI: One of the redirect URIs registered for this client.
    ///   - scopes: The account scopes to ask for, e.g. `["user.read"]`.
    ///   - state: An unguessable value tied to the person's session, checked when
    ///     they come back (CSRF protection).
    ///   - resources: Other services' APIs to use as the person afterwards
    ///     (RFC 8707), by resource identifier. Their scopes go in `scopes` too;
    ///     the person consents to everything at once. Then get tokens for them
    ///     with ``AuthenticationService/resourceToken(_:forSessionOf:replacing:)``.
    public func authorizationURL(redirectURI: String, scopes: [String], state: String?, resources: [String] = []) -> URL {
        var components = URLComponents(
            url: frontendURL.appending(path: "authorize"), resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientIdentifier),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
        ] + (state.map { [URLQueryItem(name: "state", value: $0)] } ?? [])
            + resources.map { URLQueryItem(name: "resource", value: $0) }
        return components.url!
    }
}

public enum AccountsConfigurationError: Error, CustomStringConvertible {
    case invalidURL(key: String, value: String)

    public var description: String {
        switch self {
        case .invalidURL(let key, let value): "\(key) is not an http(s) URL: \(value)"
        }
    }
}
