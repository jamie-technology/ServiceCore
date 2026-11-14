public import Configuration
public import FoundationDB
import Logging

// FoundationDB wiring, shared by every service.
//
// Each service gets its own tenant, so their key spaces cannot collide and a
// service can later be moved to its own cluster without touching its code.

/// Where a service's FoundationDB data lives.
public struct FoundationDBConfiguration: Sendable, Hashable {
    /// The cluster file to connect with, or `nil` for the client's default.
    public var clusterFilePath: String?

    /// The tenant holding this service's data.
    public var tenant: String

    public init(clusterFilePath: String? = nil, tenant: String) {
        self.clusterFilePath = clusterFilePath
        self.tenant = tenant
    }

    /// Reads `fdb.cluster.file` and `fdb.tenant` from `config`
    /// (`FDB_CLUSTER_FILE` and `FDB_TENANT` in the environment), falling back to
    /// `defaultTenant`.
    public init(config: ConfigReader, defaultTenant: String) {
        self.init(
            clusterFilePath: config.string(forKey: "fdb.cluster.file"),
            tenant: config.string(forKey: "fdb.tenant", default: defaultTenant)
        )
    }
}

/// A service's connection to its FoundationDB tenant.
public struct FoundationDBConnection: Sendable {
    public let database: FDBDatabase
    public let tenant: FDBTenant
    public let tenantName: String

    public init(database: FDBDatabase, tenant: FDBTenant, tenantName: String) {
        self.database = database
        self.tenant = tenant
        self.tenantName = tenantName
    }

    /// Connects to FoundationDB and opens the configured tenant, creating it if
    /// it does not exist.
    ///
    /// By default this waits until the tenant exists before returning, so a
    /// service only starts serving once its database is usable: on a fresh
    /// cluster it can start before the database is configured or tenants are
    /// enabled. An existing tenant is the normal outcome on restart, not a
    /// failure.
    ///
    /// - Parameter retryInterval: How long to wait between attempts to create
    ///   the tenant. Pass `nil` to try once and throw on failure.
    public static func connect(
        _ configuration: FoundationDBConfiguration,
        retryInterval: Duration? = .seconds(2)
    ) async throws -> FoundationDBConnection {
        // Process-wide and idempotent, so several connections can call it.
        try await FDBClient.initialize()

        let database = try FDBClient.openDatabase(clusterFilePath: configuration.clusterFilePath)
        try await ensureTenant(configuration.tenant, in: database, retryInterval: retryInterval)
        let tenant = try database.openTenant(name: configuration.tenant)

        Logger.current.info(
            "FoundationDB ready", metadata: ["tenant": .string(configuration.tenant)]
        )
        return FoundationDBConnection(
            database: database, tenant: tenant, tenantName: configuration.tenant
        )
    }

    /// Connects using `fdb.cluster.file` and `fdb.tenant` from `config`.
    public static func connect(
        defaultTenant: String,
        config: ConfigReader,
        retryInterval: Duration? = .seconds(2)
    ) async throws -> FoundationDBConnection {
        try await connect(
            FoundationDBConfiguration(config: config, defaultTenant: defaultTenant),
            retryInterval: retryInterval
        )
    }

    /// Creates the tenant unless it already exists, retrying anything else
    /// (tenants not enabled yet, a cluster still coming up) until it works. A
    /// transaction against an unconfigured database waits rather than failing,
    /// so this also waits for the database to be configured.
    private static func ensureTenant(
        _ name: String, in database: FDBDatabase, retryInterval: Duration?
    ) async throws {
        while true {
            do {
                try await database.createTenant(name: name)
                return
            } catch let error as FDBError where error.code == FDBErrorCodes.tenantAlreadyExists {
                return
            } catch {
                guard let retryInterval else { throw error }
                Logger.current.warning(
                    "Can't create the FoundationDB tenant yet; retrying",
                    metadata: ["tenant": .string(name), "error": .string(String(describing: error))]
                )
                try await Task.sleep(for: retryInterval)
            }
        }
    }

    /// Runs `operation` in a transaction against this service's tenant, inside
    /// the bindings' retry loop, committing if it returns.
    public func withTransaction<T: Sendable>(
        _ operation: @Sendable (any TransactionProtocol) async throws -> T
    ) async throws -> T {
        try await tenant.withTransaction(operation)
    }
}

/// FoundationDB error codes the services branch on.
///
/// The bindings expose `FDBError.code` as a raw `Int32`; these name the ones
/// worth matching rather than leaving magic numbers at call sites.
public enum FDBErrorCodes {
    public static let notCommitted: Int32 = 1020
    public static let transactionTooOld: Int32 = 1007
    public static let transactionTimedOut: Int32 = 1031
    public static let transactionTooLarge: Int32 = 2101
    public static let keyTooLarge: Int32 = 2102
    public static let valueTooLarge: Int32 = 2103
    public static let tenantNotFound: Int32 = 2131
    public static let tenantAlreadyExists: Int32 = 2132
    public static let tenantsDisabled: Int32 = 2136
}

extension FDBError {
    /// Whether this is FoundationDB refusing a write that is too big: a key,
    /// a value, or the whole transaction. A request that hits one of these will
    /// fail the same way however often it is retried.
    public var isSizeLimit: Bool {
        code == FDBErrorCodes.transactionTooLarge
            || code == FDBErrorCodes.keyTooLarge
            || code == FDBErrorCodes.valueTooLarge
    }
}
