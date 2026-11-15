public import Foundation
import Logging
import Synchronization

/// An access token for another service's API (RFC 8707), acting for a person signed in to this service.
public struct ResourceToken: Sendable, Hashable {
    /// The API's resource identifier.
    public var resource: String
    public var accessToken: String
    public var expiresAt: Date
    /// Which access token this is for that API (`access_token_generation`). Pass the token back as `replacing` when
    /// the API refuses it, to get the next one.
    public var generation: UInt64?
}

extension AuthenticationService {
    /// A token for another service's API, acting for the person whose session `accessToken` (their token for this
    /// service) belongs to: call the other service with it, and it applies *their* authority.
    ///
    /// The person must have consented to `resource` when signing in: ask for it with
    /// ``AccountsConfiguration/authorizationURL(redirectURI:scopes:state:resources:)``. Tokens are cached until a
    /// minute before they expire. If the API refuses one before then (revoked, say), pass it as `replacing` to get the
    /// next generation; any number of callers doing that at once get the same new token.
    ///
    /// - Throws: ``AuthenticationErrorCode/resourceNotGranted`` if the sign-in doesn't cover `resource` (or this
    ///   service's client was taken off its allow-list); ``AuthenticationErrorCode/signInRequired`` if the grant is
    ///   gone; ``AuthenticationErrorCode/invalidAccessToken`` if `accessToken` is no session's current token.
    public func resourceToken(_ resource: String, forSessionOf accessToken: String, replacing stale: ResourceToken? = nil) async throws -> ResourceToken {
        guard let session = try await store.session(forToken: TokenDigest(token: accessToken)) else {
            throw AuthenticationError.invalidAccessToken()
        }
        let key = ResourceTokenCache.Key(session: session.id, resource: resource)
        if let cached = resourceTokens.get(key), cached.accessToken != stale?.accessToken,
           cached.expiresAt.timeIntervalSinceNow > 60 {
            return cached
        }

        let grant: TokenGrant
        do {
            grant = try await accounts.refresh(refreshToken: session.refreshToken, resource: resource, expectedGeneration: stale?.generation)
        } catch let error as AccountsOAuthError where error.isInvalidGrant {
            _ = try? await store.replace(session.id, expected: session, with: nil)
            throw AuthenticationError.signInRequired()
        } catch let error as AccountsOAuthError where error.isInvalidTarget {
            throw AuthenticationError.resourceNotGranted(resource)
        } catch let error as AccountsOAuthError where error.isStaleGeneration {
            // Someone has moved past `stale` already: whatever is current is newer.
            return try await resourceToken(resource, forSessionOf: accessToken)
        } catch let error as AccountsOAuthError {
            throw Self.unavailable(error)
        }

        let token = ResourceToken(
            resource: resource, accessToken: grant.accessToken,
            expiresAt: Date(timeIntervalSinceNow: TimeInterval(grant.expiresIn)), generation: grant.generation
        )
        resourceTokens.set(key, token)
        return token
    }
}

extension AccountsOAuthError {
    /// The resource isn't one the grant covers, or the client is off its allow-list (RFC 8707 `invalid_target`).
    public var isInvalidTarget: Bool {
        if case .rejected(code: "invalid_target", _) = self { return true }
        return false
    }
}

/// Resource tokens by session and resource, in memory.
final class ResourceTokenCache: Sendable {
    struct Key: Hashable, Sendable {
        let session: UUID
        let resource: String
    }

    private let tokens = Mutex<[Key: ResourceToken]>([:])

    func get(_ key: Key) -> ResourceToken? {
        tokens.withLock { $0[key] }
    }

    func set(_ key: Key, _ token: ResourceToken) {
        tokens.withLock { tokens in
            tokens[key] = token
            // Forget expired ones as new ones arrive, so the cache stays the size of what's in use.
            if tokens.count > 1_000 {
                tokens = tokens.filter { $0.value.expiresAt > Date() }
            }
        }
    }
}
