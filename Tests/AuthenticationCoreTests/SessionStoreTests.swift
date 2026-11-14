import AuthenticationCore
import AuthenticationFoundationDB
import Configuration
import FDBRecordLayer
import Foundation
import FoundationDBCore
import RecordStore
import Testing

private func session(token: String = "access-\(UUID())", generation: UInt64 = 0, expiresAt: Date) -> SessionRecord {
    SessionRecord(
        id: UUID(), tokenDigest: TokenDigest(token: token), generation: generation, refreshToken: "refresh",
        subject: "ada", scopes: ["user.read", "group.read"], signedInAt: 1_794_153_600_123, expiresAt: expiresAt
    )
}

/// The contract every store must meet.
private func checkContract(_ store: some SessionStore, now: TestClock) async throws {
    let start = now.now
    let first = session(token: "t0", expiresAt: start + 3600)
    let id = first.id

    #expect(try await store.session(id: id) == nil)
    #expect(try await store.replace(id, expected: first, with: first) == false)
    #expect(try await store.replace(id, expected: nil, with: first))
    #expect(try await store.session(id: id) == first)
    #expect(try await store.session(forToken: TokenDigest(token: "t0")) == first)
    #expect(try await store.replace(id, expected: nil, with: first) == false)

    // Moving to a new token: only the current token finds the session.
    var second = first
    second.tokenDigest = TokenDigest(token: "t1")
    second.generation = 1
    #expect(try await store.replace(id, expected: first, with: second))
    #expect(try await store.session(forToken: TokenDigest(token: "t0")) == nil)
    #expect(try await store.session(forToken: TokenDigest(token: "t1")) == second)
    #expect(try await store.replace(id, expected: first, with: first) == false)

    // Other sessions are separate.
    let other = session(token: "other", expiresAt: start + 3600)
    #expect(try await store.replace(other.id, expected: nil, with: other))
    #expect(try await store.session(forToken: TokenDigest(token: "other")) == other)
    #expect(try await store.session(forToken: TokenDigest(token: "t1")) == second)

    // Expired sessions read as absent, and can be overwritten as if absent.
    now.set(start + 3601)
    #expect(try await store.session(id: id) == nil)
    #expect(try await store.session(forToken: TokenDigest(token: "t1")) == nil)
    var renewed = second
    renewed.expiresAt = start + 7200
    #expect(try await store.replace(id, expected: nil, with: renewed))
    #expect(try await store.replace(id, expected: renewed, with: nil))
    #expect(try await store.session(id: id) == nil)
}

@Suite(.serialized) struct SessionStoreTests {
    @Test func inMemory() async throws {
        let now = TestClock()
        try await checkContract(InMemorySessionStore(now: { now.now }), now: now)
    }

    @Test func foundationDB() async throws {
        let now = TestClock()
        let connection = try await FoundationDBConnection.connect(
            FoundationDBConfiguration(tenant: "servicecore-tests"), retryInterval: nil
        )
        let store = FoundationDBSessionStore(
            connection: connection, path: "auth-test-\(UUID().uuidString.prefix(8))", now: { now.now }
        )
        try await checkContract(store, now: now)

        // Sweeping removes exactly the expired sessions.
        now.set(Date(timeIntervalSince1970: 2_000_000))
        let live = session(expiresAt: Date(timeIntervalSince1970: 2_000_100))
        let dead = session(expiresAt: Date(timeIntervalSince1970: 2_000_010))
        #expect(try await store.replace(live.id, expected: nil, with: live))
        #expect(try await store.replace(dead.id, expected: nil, with: dead))
        now.set(Date(timeIntervalSince1970: 2_000_050))
        #expect(try await store.removeExpired() >= 1)
        #expect(try await store.session(id: live.id) == live)

        try await store.database.withStore { try await $0.deleteAllRecords() }
    }

    @Test func refreshesThroughFoundationDB() async throws {
        let connection = try await FoundationDBConnection.connect(
            FoundationDBConfiguration(tenant: "servicecore-tests"), retryInterval: nil
        )
        let store = FoundationDBSessionStore(connection: connection, path: "auth-test-\(UUID().uuidString.prefix(8))")
        let accounts = FakeAccounts()
        let service = AuthenticationService(accounts: accounts, store: store)
        let old = try await service.signIn(code: accounts.code(for: "ada"), redirectURI: nil).accessToken
        accounts.expire(old)
        accounts.delayRefreshes(.milliseconds(50))

        let results = try await withThrowingTaskGroup(of: UpdatedAccessToken?.self) { group in
            for _ in 0..<6 {
                group.addTask { try await service.authenticate(accessToken: old).updated }
            }
            return try await group.reduce(into: [UpdatedAccessToken?]()) { $0.append($1) }
        }
        #expect(accounts.tokensIssued == 1)
        #expect(Set(results).count == 1)
        let new = try #require(results.first ?? nil)
        #expect(try await store.session(forToken: TokenDigest(token: new.accessToken))?.generation == 1)
        await #expect(throws: AuthenticationError.self) { try await service.authenticate(accessToken: old) }

        try await store.database.withStore { try await $0.deleteAllRecords() }
    }
}

@Suite struct AccountsConfigurationTests {
    @Test func readsConfiguration() throws {
        let config = ConfigReader(provider: InMemoryProvider(values: [
            "accounts.client.identifier": "notes",
            "accounts.client.secret": "s3cret",
            "accounts.frontend.url": "https://accounts.example",
            "accounts.api.url": "https://api.accounts.example/v1",
        ]))
        let configuration = try AccountsConfiguration(config: config)
        #expect(configuration.clientIdentifier == "notes")
        #expect(configuration.apiURL.absoluteString == "https://api.accounts.example/v1")

        let url = configuration.authorizationURL(
            redirectURI: "notes://signed-in", scopes: ["user.read", "group.read"], state: "xyz"
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "accounts.example")
        #expect(components.path == "/authorize")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query == [
            "response_type": "code", "client_id": "notes", "redirect_uri": "notes://signed-in",
            "scope": "user.read group.read", "state": "xyz",
        ])
    }

    @Test func rejectsBadURLs() {
        let config = ConfigReader(provider: InMemoryProvider(values: [
            "accounts.client.identifier": "notes", "accounts.client.secret": "s",
            "accounts.frontend.url": "not a url", "accounts.api.url": "https://a.example",
        ]))
        #expect(throws: AccountsConfigurationError.self) { try AccountsConfiguration(config: config) }
    }
}
