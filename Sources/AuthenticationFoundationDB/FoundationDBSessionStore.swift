public import AuthenticationCore
import FDBRecordLayer
import FoundationDB
public import FoundationDBCore
public import Foundation
public import RecordStore
import SwiftProtobuf

/// The Record Layer schema sessions are stored with. Its own store, at its own
/// path, so it never shares metadata versions with the service's schema.
let sessionSchema = RecordMetaData(version: 1) {
    RecordType(AuthDbSession.self, key: 1, primaryKey: \.id)
        .index("session.tokenDigest", on: \.tokenDigest, key: 101)
        .index("session.expiresAt", on: \.expiresAt, key: 102)
}

/// An ``AuthenticationCore/SessionStore`` in a service's FoundationDB tenant,
/// on the Record Layer.
///
/// Sessions are `servicecore.auth.v1.Session` records in a record store of
/// their own (at `path`, `auth-sessions` by default), keyed by session ID and
/// indexed by current token digest and by expiry. The compare-and-swap reads
/// and writes in one transaction, so FoundationDB's conflict detection makes it
/// atomic across every instance of the service.
///
/// Expired sessions read as absent. Nothing deletes them by itself: call
/// ``removeExpired(limit:)`` periodically (a daily task is plenty).
public struct FoundationDBSessionStore: SessionStore {
    public let database: RecordDatabase
    private let now: @Sendable () -> Date

    /// - Parameter path: The record store's path within the tenant. Pick one
    ///   that is not the service's own record store path.
    public init(connection: FoundationDBConnection, path: String = "auth-sessions", now: @escaping @Sendable () -> Date = Date.init) {
        self.database = RecordDatabase(connection: connection, metaData: sessionSchema, path: path)
        self.now = now
    }

    public func session(id: UUID) async throws -> SessionRecord? {
        let now = now()
        return try await database.withStore { store in
            try await Self.live(store, id: id, now: now)
        }
    }

    public func session(forToken digest: TokenDigest) async throws -> SessionRecord? {
        let now = now()
        return try await database.withStore { store in
            let matches = try await store.executeQuery(
                RecordQuery(AuthDbSession.self).where(Query.field(\.tokenDigest).equals(digest.hex)).limited(to: 1)
            ).collect()
            return matches.first.flatMap { SessionRecord($0.record) }.flatMap { $0.isExpired(at: now) ? nil : $0 }
        }
    }

    public func replace(_ id: UUID, expected: SessionRecord?, with new: SessionRecord?) async throws -> Bool {
        let now = now()
        return try await database.withStore { store in
            let current = try await Self.live(store, id: id, now: now)
            // Already `new`: this transaction's earlier run committed (`new` holds a fresh token digest, so only
            // this swap writes it).
            guard current != new else { return true }
            guard current == expected else { return false }
            if let new {
                _ = try await store.save(AuthDbSession(new))
            } else {
                try await store.delete(AuthDbSession.self, primaryKey: Tuple(id.uuidString))
            }
            return true
        }
    }

    /// Deletes up to `limit` expired sessions, returning how many it deleted.
    /// Call it until it returns less than `limit` to sweep everything.
    @discardableResult
    public func removeExpired(limit: Int = 500) async throws -> Int {
        let cutoff = Int64(now().timeIntervalSince1970)
        return try await database.withStore { store in
            let expired = try await store.executeQuery(
                RecordQuery(AuthDbSession.self)
                    .where(Query.field(\.expiresAt).lessThanOrEquals(cutoff))
                    .limited(to: limit)
            ).collect()
            for record in expired {
                try await store.delete(AuthDbSession.self, primaryKey: Tuple(record.record.id))
            }
            return expired.count
        }
    }

    private static func live(_ store: FDBRecordStore, id: UUID, now: Date) async throws -> SessionRecord? {
        guard let stored = try await store.load(AuthDbSession.self, primaryKey: Tuple(id.uuidString))?.record else {
            return nil
        }
        // An unreadable record is treated as no session: the person signs in again.
        guard let session = SessionRecord(stored), !session.isExpired(at: now) else { return nil }
        return session
    }
}

extension AuthDbSession {
    init(_ session: SessionRecord) {
        self.init()
        id = session.id.uuidString
        tokenDigest = session.tokenDigest.hex
        generation = session.generation
        refreshToken = session.refreshToken
        subject = session.subject
        scopes = session.scopes
        signedInAt = session.signedInAt
        expiresAt = Int64(session.expiresAt.timeIntervalSince1970)
    }
}

extension SessionRecord {
    init?(_ stored: AuthDbSession) {
        guard let id = UUID(uuidString: stored.id), let digest = TokenDigest(hex: stored.tokenDigest) else { return nil }
        self.init(
            id: id, tokenDigest: digest, generation: stored.generation, refreshToken: stored.refreshToken,
            subject: stored.subject, scopes: stored.scopes, signedInAt: stored.signedInAt,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(stored.expiresAt))
        )
    }
}
