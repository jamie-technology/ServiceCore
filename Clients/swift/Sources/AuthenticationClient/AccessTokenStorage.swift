import Foundation
import os

/// Where the access token lives, shared by every process that uses it (an app
/// and its extensions).
///
/// Implementations must make "keep the highest version" hold however writes
/// from different processes interleave, without relying on a compare-and-set
/// the underlying storage may not have. ``KeychainAccessTokenStorage`` does it
/// by never overwriting: every version is its own item, and the highest wins.
public protocol AccessTokenStorage: Sendable {
    /// The highest-version token stored, or `nil` when signed out.
    func current() throws -> StoredAccessToken?

    /// Stores `token` unless a higher version is already stored, and tells
    /// every process using the storage. Returns whether `token` is now current.
    @discardableResult
    func offer(_ token: StoredAccessToken) throws -> Bool

    /// Removes tokens up to and including `version`: after the service said the
    /// session has ended. A token from a newer sign-in, stored meanwhile by
    /// another process, survives.
    func remove(upTo version: AccessTokenVersion) throws

    /// Removes every token: signing out.
    func removeAll() throws

    /// Yields whenever any process changes the storage. Changes may be
    /// coalesced: read ``current()`` after each.
    func changes() -> AsyncStream<Void>
}

extension AccessTokenStorage {
    /// Waits up to `timeout` for a token with a version higher than `version`
    /// to be stored, by this process or another. Returns it, or `nil`.
    public func waitForNewer(than version: AccessTokenVersion, timeout: Duration) async throws -> StoredAccessToken? {
        // Subscribe before looking, so a change between the two is not missed.
        let changes = changes()
        if let current = try current(), current.version > version { return current }

        return try await withThrowingTaskGroup(of: StoredAccessToken?.self) { group in
            group.addTask {
                for await _ in changes {
                    if let current = try current(), current.version > version { return current }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            if let first { return first }
            // Notifications can be coalesced or lost: look once more at the deadline.
            if let current = try current(), current.version > version { return current }
            return nil
        }
    }
}

/// An ``AccessTokenStorage`` in memory, for tests and for a single process
/// that does not need to stay signed in across launches.
public final class InMemoryAccessTokenStorage: AccessTokenStorage {
    private let state = OSAllocatedUnfairLock<(token: StoredAccessToken?, listeners: [UUID: AsyncStream<Void>.Continuation])>(initialState: (nil, [:]))

    public init(_ token: StoredAccessToken? = nil) {
        state.withLock { $0.token = token }
    }

    public func current() throws -> StoredAccessToken? {
        state.withLock { $0.token }
    }

    public func offer(_ token: StoredAccessToken) throws -> Bool {
        let stored = state.withLock { state -> Bool in
            if let current = state.token, current.version >= token.version { return current == token }
            state.token = token
            return true
        }
        notify()
        return stored
    }

    public func remove(upTo version: AccessTokenVersion) throws {
        state.withLock { state in
            if let current = state.token, current.version <= version { state.token = nil }
        }
        notify()
    }

    public func removeAll() throws {
        state.withLock { $0.token = nil }
        notify()
    }

    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        state.withLock { $0.listeners[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.listeners.removeValue(forKey: id) }
        }
        return stream
    }

    private func notify() {
        state.withLock { Array($0.listeners.values) }.forEach { $0.yield() }
    }
}
