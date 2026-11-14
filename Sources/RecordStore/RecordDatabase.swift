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
    /// commits if it returns and retries if FoundationDB reports a conflict.
    ///
    /// `operation` may run more than once, so it must not have side effects
    /// outside the transaction.
    public func withStore<T: Sendable>(
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
