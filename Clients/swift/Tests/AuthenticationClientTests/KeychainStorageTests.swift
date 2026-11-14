@testable import AuthenticationClient
import Foundation
import Testing

private func version(_ generation: UInt64, signedInAt: UInt64 = 1_794_153_600_000) -> AccessTokenVersion {
    AccessTokenVersion(signedInAt: signedInAt, generation: generation)
}

/// Uses the login keychain (no data-protection keychain without a signed app),
/// under a unique service name, cleared afterwards. Two storage instances on
/// one service stand in for an app and its extension.
@Suite(.serialized) struct KeychainStorageTests {
    let service = "servicecore.tests.\(UUID().uuidString)"

    private func storage() -> KeychainAccessTokenStorage {
        KeychainAccessTokenStorage(service: service, useDataProtectionKeychain: false)
    }

    @Test func keepsTheHighestVersion() throws {
        let app = storage(), extensionStorage = storage()
        defer { try? app.removeAll() }

        #expect(try app.current() == nil)
        #expect(try app.offer(StoredAccessToken(accessToken: "t1", version: version(1))))
        #expect(try extensionStorage.current()?.accessToken == "t1")

        // Older versions are refused, wherever they come from.
        #expect(try extensionStorage.offer(StoredAccessToken(accessToken: "t0", version: version(0))) == false)
        #expect(try extensionStorage.offer(StoredAccessToken(accessToken: "t2", version: version(2))))
        #expect(try app.offer(StoredAccessToken(accessToken: "t1", version: version(1))) == false)
        #expect(try app.current()?.accessToken == "t2")

        // A new sign-in outranks every token of the old one.
        let signedInAgain = StoredAccessToken(accessToken: "s0", version: version(0, signedInAt: 1_794_153_700_000))
        #expect(try app.offer(signedInAgain))
        #expect(try extensionStorage.current() == signedInAgain)
    }

    @Test func prunesAndRemoves() throws {
        let app = storage()
        defer { try? app.removeAll() }
        try app.offer(StoredAccessToken(accessToken: "t1", version: version(1)))
        try app.offer(StoredAccessToken(accessToken: "t2", version: version(2)))
        try app.remove(upTo: version(1))
        #expect(try app.current()?.accessToken == "t2")
        try app.remove(upTo: version(2))
        #expect(try app.current() == nil)
    }

    @Test func otherInstancesHearAboutNewTokens() async throws {
        let app = storage(), extensionStorage = storage()
        defer { try? app.removeAll() }
        try app.offer(StoredAccessToken(accessToken: "t0", version: version(0)))

        Task {
            try await Task.sleep(for: .milliseconds(200))
            try extensionStorage.offer(StoredAccessToken(accessToken: "t1", version: version(1)))
        }
        let started = ContinuousClock.now
        let newer = try await app.waitForNewer(than: version(0), timeout: .seconds(5))
        #expect(newer?.accessToken == "t1")
        // Woken by the notification, not by the deadline.
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func accountNamesSortByVersion() {
        let names = [version(10), version(9), version(0, signedInAt: 1_794_153_700_000)]
            .map(KeychainAccessTokenStorage.account(for:))
        #expect(names.sorted() == [names[1], names[0], names[2]])
        #expect(names.map(KeychainAccessTokenStorage.version(fromAccount:)) == [version(10), version(9), version(0, signedInAt: 1_794_153_700_000)])
    }
}
