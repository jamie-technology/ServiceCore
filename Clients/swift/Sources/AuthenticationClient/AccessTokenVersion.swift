/// Orders a person's access tokens, across sign-ins as well as refreshes.
/// Keep the token with the highest version you have been given.
///
/// Compared as (`signedInAt`, `generation`). On the wire it is
/// `<signedInAt>.<generation>`, e.g. `1794153600000.3`, as sent in
/// `X-Updated-Access-Token-Version` and by the service's sign-in endpoint.
public struct AccessTokenVersion: Sendable, Hashable, Comparable, LosslessStringConvertible, Codable {
    /// When the session was signed in, in Unix milliseconds.
    public var signedInAt: UInt64
    /// How many times the session has been refreshed.
    public var generation: UInt64

    public init(signedInAt: UInt64, generation: UInt64) {
        self.signedInAt = signedInAt
        self.generation = generation
    }

    public init?(_ description: String) {
        let parts = description.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let signedInAt = UInt64(parts[0]), let generation = UInt64(parts[1]) else {
            return nil
        }
        self.init(signedInAt: signedInAt, generation: generation)
    }

    public var description: String { "\(signedInAt).\(generation)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.signedInAt, lhs.generation) < (rhs.signedInAt, rhs.generation)
    }
}

/// An access token and its version.
public struct StoredAccessToken: Sendable, Hashable, Codable {
    public var accessToken: String
    public var version: AccessTokenVersion

    public init(accessToken: String, version: AccessTokenVersion) {
        self.accessToken = accessToken
        self.version = version
    }
}
