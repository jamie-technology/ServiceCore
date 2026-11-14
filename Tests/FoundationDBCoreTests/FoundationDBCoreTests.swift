import Configuration
import FoundationDB
import FoundationDBCore
import Testing

@Suite struct FoundationDBConfigurationTests {
    @Test func readsTheTenantAndClusterFile() {
        let config = ConfigReader(provider: InMemoryProvider(values: [
            "fdb.cluster.file": "/etc/foundationdb/fdb.cluster",
            "fdb.tenant": "custom",
        ]))
        let configuration = FoundationDBConfiguration(config: config, defaultTenant: "fallback")
        #expect(configuration.clusterFilePath == "/etc/foundationdb/fdb.cluster")
        #expect(configuration.tenant == "custom")
    }

    @Test func fallsBackToTheDefaultTenant() {
        let config = ConfigReader(provider: InMemoryProvider(values: [:]))
        let configuration = FoundationDBConfiguration(config: config, defaultTenant: "fallback")
        #expect(configuration.clusterFilePath == nil)
        #expect(configuration.tenant == "fallback")
    }
}

/// Runs against the local FoundationDB cluster.
@Suite struct FoundationDBConnectionTests {
    @Test func connectsTwiceToTheSameTenant() async throws {
        let configuration = FoundationDBConfiguration(tenant: "servicecore-tests")
        // The second connect finds the tenant already there, which must not fail.
        _ = try await FoundationDBConnection.connect(configuration, retryInterval: nil)
        let connection = try await FoundationDBConnection.connect(configuration, retryInterval: nil)
        #expect(connection.tenantName == "servicecore-tests")

        let key: [UInt8] = Array("servicecore-core-test".utf8)
        try await connection.withTransaction { transaction in
            transaction.setValue([1, 2, 3], for: key)
        }
        let value = try await connection.withTransaction { transaction in
            try await transaction.getValue(for: key)
        }
        #expect(value == [1, 2, 3])
        try await connection.withTransaction { transaction in
            transaction.clear(key: key)
        }
    }
}
