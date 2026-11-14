import Crypto
public import Foundation
import Synchronization

/// Where a service keeps its signed-in sessions: above all each session's
/// refresh token, which only the service ever sees.
///
/// A store is a map from session ID to ``SessionRecord`` with an atomic
/// compare-and-swap, plus one lookup: the session whose *current* access token
/// has a given digest. ``AuthenticationService`` holds all the logic, so any
/// database that can do a conditional write and a secondary lookup can back
/// it. `AuthenticationFoundationDB` provides one on the Record Layer, and
/// ``InMemorySessionStore`` one for tests and single-process development.
///
/// Access tokens are only ever stored as digests, so reading the store does
/// not hand out working access tokens. The refresh tokens it holds are only
/// usable with this service's client secret.
public protocol SessionStore: Sendable {
    /// The session with this ID, or `nil` if there is none or it has expired
    /// (``SessionRecord/expiresAt``).
    func session(id: UUID) async throws -> SessionRecord?

    /// The session whose current access token has this digest, or `nil`.
    /// A replaced token's digest finds nothing: only the current one is kept.
    func session(forToken digest: TokenDigest) async throws -> SessionRecord?

    /// Atomically: if the session stored under `id` is `expected` (`nil`: there
    /// is none, or only an expired one), replaces it with `new` (`nil`: deletes
    /// it) and returns `true`. Otherwise changes nothing and returns `false`.
    func replace(_ id: UUID, expected: SessionRecord?, with new: SessionRecord?) async throws -> Bool
}

/// The SHA-256 of an access token: how stores find a session by token.
public struct TokenDigest: Sendable, Hashable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init(token: String) {
        bytes = Array(SHA256.hash(data: Data(token.utf8)))
    }

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    public init?(hex: String) {
        guard hex.utf8.count == 64 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.bytes = bytes
    }

    public var hex: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public var description: String { hex }
}

extension TokenDigest: Codable {
    public init(from decoder: any Decoder) throws {
        let hex = try decoder.singleValueContainer().decode(String.self)
        guard let digest = TokenDigest(hex: hex) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a SHA-256 hex digest"))
        }
        self = digest
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// Orders a person's access tokens, across sign-ins as well as refreshes. Sent
/// to clients with every token so they keep the newest one they were given.
///
/// Compared as (`signedInAt`, `generation`). The generation counts refreshes
/// within one sign-in and starts again at 0 for the next, so on its own it
/// would rank a dead token from an earlier session above a new one.
///
/// On the wire it is `<signedInAt>.<generation>`, both decimal, `signedInAt` in
/// Unix milliseconds: e.g. `1794153600000.3`.
public struct AccessTokenVersion: Sendable, Hashable, Comparable, LosslessStringConvertible {
    /// When the session was signed in, in Unix milliseconds.
    public var signedInAt: UInt64
    /// accounts' `access_token_generation`.
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

/// One signed-in session.
///
/// Stores persist it field by field (or with `Codable`) and compare it whole
/// (it is `Equatable`). `expiresAt` is whole seconds, so it survives any
/// encoding unchanged and a stored record still equals the one written.
public struct SessionRecord: Codable, Sendable, Hashable {
    /// Stable for the session's life. The primary key.
    public var id: UUID

    /// The digest of the session's current access token.
    public var tokenDigest: TokenDigest

    /// accounts' generation of the current access token. Only ever increases.
    public var generation: UInt64

    public var refreshToken: String

    /// The account's identifier.
    public var subject: String
    public var scopes: [String]

    /// When the session was signed in, in Unix milliseconds.
    public var signedInAt: UInt64

    /// When a store may forget this session: pushed back on every refresh.
    public var expiresAt: Date

    public init(
        id: UUID, tokenDigest: TokenDigest, generation: UInt64, refreshToken: String,
        subject: String, scopes: [String], signedInAt: UInt64, expiresAt: Date
    ) {
        self.id = id
        self.tokenDigest = tokenDigest
        self.generation = generation
        self.refreshToken = refreshToken
        self.subject = subject
        self.scopes = scopes
        self.signedInAt = signedInAt
        self.expiresAt = expiresAt.wholeSeconds
    }

    /// The current access token's version.
    public var version: AccessTokenVersion {
        AccessTokenVersion(signedInAt: signedInAt, generation: generation)
    }

    public func isExpired(at now: Date) -> Bool {
        expiresAt <= now
    }
}

extension Date {
    /// Rounded down to a whole second, so it encodes exactly.
    var wholeSeconds: Date {
        Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down))
    }
}

/// A ``SessionStore`` in memory: for tests, and for a single process that can
/// afford to sign everyone out when it restarts.
public final class InMemorySessionStore: SessionStore {
    private let sessions = Mutex<[UUID: SessionRecord]>([:])
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    public func session(id: UUID) async throws -> SessionRecord? {
        let now = now()
        return sessions.withLock { $0[id].flatMap { $0.isExpired(at: now) ? nil : $0 } }
    }

    public func session(forToken digest: TokenDigest) async throws -> SessionRecord? {
        let now = now()
        return sessions.withLock { sessions in
            sessions.values.first { $0.tokenDigest == digest && !$0.isExpired(at: now) }
        }
    }

    public func replace(_ id: UUID, expected: SessionRecord?, with new: SessionRecord?) async throws -> Bool {
        let now = now()
        return sessions.withLock { sessions in
            let current = sessions[id].flatMap { $0.isExpired(at: now) ? nil : $0 }
            guard current == expected else { return false }
            sessions[id] = new
            return true
        }
    }

    /// How many sessions are stored, expired ones included.
    public var count: Int {
        sessions.withLock { $0.count }
    }
}
