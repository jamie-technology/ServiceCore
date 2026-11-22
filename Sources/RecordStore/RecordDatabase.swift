public import FDBRecordLayer
public import FoundationDB
public import FoundationDBCore

/// A service's Record Layer store: a schema at a path within its tenant.
///
/// Build one at startup and hand it to whatever needs the database. Every
/// call opens the store inside a fresh transaction rather than caching one,
/// which keeps every caller inside the bindings' retry loop. That is what
/// makes conflict retries automatic instead of something each call site has to
/// remember.
public struct RecordDatabase: Sendable {
    public let connection: FoundationDBConnection
    public let metaData: RecordMetaData
    public let path: KeySpacePath

    /// - Parameters:
    ///   - connection: The tenant to store records in.
    ///   - metaData: The schema. Give every record type and index an explicit
    ///     key: positional keys mean reordering declarations silently moves
    ///     every existing record.
    ///   - path: The subspace the store occupies within the tenant.
    public init(connection: FoundationDBConnection, metaData: RecordMetaData, path: KeySpacePath) {
        self.connection = connection
        self.metaData = metaData
        self.path = path
    }

    /// A store at a named subspace within the tenant, e.g. `"records"`.
    public init(connection: FoundationDBConnection, metaData: RecordMetaData, path: String) {
        self.init(connection: connection, metaData: metaData, path: KeySpacePath(path))
    }

    /// Runs `operation` against the record store in one transaction, which
    /// commits if it returns and retries if FoundationDB says to.
    ///
    /// `operation` may run more than once, so it must not have side effects
    /// outside the transaction. And it may run again *after an earlier run
    /// committed*: FoundationDB retries `commit_unknown_result` (and
    /// `cluster_version_changed`) without knowing whether the commit happened.
    /// So a write must be idempotent: make an ID (and anything the response
    /// names) before calling this; first check for an applied-request record
    /// under that ID, which only this transaction writes, and write it with
    /// the changes. Found: the earlier run committed, so return what it would
    /// have. One ID per write transaction: a request with several needs one
    /// for each. See the README's "Idempotent transactions".
    ///
    /// Test that with ``retriesAfterCommit``.
    public func withStore<T: Sendable>(
        _ operation: @Sendable (FDBRecordStore) async throws -> T
    ) async throws -> T {
        let result = try await run(operation)
        guard Self.retriesAfterCommit else { return result }
        return try await run(operation)
    }

    private func run<T: Sendable>(
        _ operation: @Sendable (FDBRecordStore) async throws -> T
    ) async throws -> T {
        let metaData = self.metaData, path = self.path
        return try await connection.tenant.withRecordContext { context in
            let store = try await FDBRecordStore.open(
                context: context, path: path, metaData: metaData
            )
            return try await operation(store)
        }
    }

    /// For tests: while `true`, every ``withStore(_:)`` transaction commits and
    /// then runs again in a new transaction, returning the second run's result.
    /// That's what FoundationDB does when a commit reports
    /// `commit_unknown_result` but did happen. Set it around a request to check
    /// the request still does exactly what it should:
    ///
    /// ```swift
    /// try await RecordDatabase.$retriesAfterCommit.withValue(true) {
    ///     try await client.execute(request)
    /// }
    /// ```
    ///
    /// A task-local, so tests running in parallel don't see each other's.
    @TaskLocal public static var retriesAfterCommit = false

    /// The same store layout at a different path, for keeping separate
    /// stores (per container, per test run) under one schema.
    public func at(_ path: KeySpacePath) -> RecordDatabase {
        RecordDatabase(connection: connection, metaData: metaData, path: path)
    }
}

extension FoundationDBConnection {
    /// Runs `operation` against the record store at `path` in this tenant.
    ///
    /// For one-off access; services that use one schema throughout should
    /// build a ``RecordDatabase`` once instead.
    public func withRecordStore<T: Sendable>(
        _ metaData: RecordMetaData,
        path: KeySpacePath,
        _ operation: @Sendable (FDBRecordStore) async throws -> T
    ) async throws -> T {
        try await RecordDatabase(connection: self, metaData: metaData, path: path)
            .withStore(operation)
    }
}
