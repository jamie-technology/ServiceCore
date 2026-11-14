import AuthenticationCore
import Foundation
import ProtobufWireCore
import Testing

private func makeService(store: any SessionStore = InMemorySessionStore()) -> (AuthenticationService, FakeAccounts) {
    let accounts = FakeAccounts()
    return (AuthenticationService(accounts: accounts, store: store), accounts)
}

@Suite struct AuthenticationServiceTests {
    @Test func signsInAndAuthenticates() async throws {
        let (service, accounts) = makeService()
        let signIn = try await service.signIn(code: accounts.code(for: "ada"), redirectURI: nil)
        #expect(signIn.account.id == "ada")
        #expect(signIn.version.generation == 0)

        let authentication = try await service.authenticate(accessToken: signIn.accessToken)
        #expect(authentication.account.id == "ada")
        #expect(authentication.account.scopes == ["user.read"])
        #expect(authentication.updated == nil)
        #expect(accounts.refreshCalls == 0)
    }

    @Test func badCodeIsRefused() async throws {
        let (service, _) = makeService()
        let error = await #expect(throws: AuthenticationError.self) {
            try await service.signIn(code: "nope", redirectURI: nil)
        }
        #expect(error?.code == .invalidAuthorizationCode)
    }

    @Test func refreshesAnExpiredToken() async throws {
        let (service, accounts) = makeService()
        let signIn = try await service.signIn(code: accounts.code(for: "ada"), redirectURI: nil)
        accounts.expire(signIn.accessToken)

        let refreshed = try await service.authenticate(accessToken: signIn.accessToken)
        let updated = try #require(refreshed.updated)
        #expect(updated.accessToken != signIn.accessToken)
        #expect(updated.version == AccessTokenVersion(signedInAt: signIn.version.signedInAt, generation: 1))
        #expect(updated.version > signIn.version)
        #expect(refreshed.account.id == "ada")
        #expect(refreshed.account.accessToken == updated.accessToken)

        // The new token works and is not refreshed again.
        #expect(try await service.authenticate(accessToken: updated.accessToken).updated == nil)

        // The old one finds no session: the client should look for a newer token.
        let error = await #expect(throws: AuthenticationError.self) {
            try await service.authenticate(accessToken: signIn.accessToken)
        }
        #expect(error?.code == .invalidAccessToken)
        #expect(accounts.tokensIssued == 1)
    }

    @Test func versionsKeepIncreasing() async throws {
        let (service, accounts) = makeService()
        let signIn = try await service.signIn(code: accounts.code(for: "ada"), redirectURI: nil)
        var token = signIn.accessToken
        var version = signIn.version
        for _ in 0..<3 {
            accounts.expire(token)
            let updated = try #require(try await service.authenticate(accessToken: token).updated)
            #expect(updated.version > version)
            (token, version) = (updated.accessToken, updated.version)
        }
        #expect(version.generation == 3)

        // A later sign-in outranks every token of the earlier one, though its generation restarts.
        try await Task.sleep(for: .milliseconds(2))
        let again = try await service.signIn(code: accounts.code(for: "ada"), redirectURI: nil)
        #expect(again.version.generation == 0)
        #expect(again.version > version)
    }

    @Test func concurrentRefreshesAllGetTheSameToken() async throws {
        let (service, accounts) = makeService()
        let old = try await service.signIn(code: accounts.code(for: "ada"), redirectURI: nil).accessToken
        accounts.expire(old)
        accounts.delayRefreshes(.milliseconds(50))

        let results = try await withThrowingTaskGroup(of: UpdatedAccessToken?.self) { group in
            for _ in 0..<8 {
                group.addTask { try await service.authenticate(accessToken: old).updated }
            }
            return try await group.reduce(into: [UpdatedAccessToken?]()) { $0.append($1) }
        }
        // No coordination: every request refreshed, but accounts issued one token.
        #expect(accounts.refreshCalls == 8)
        #expect(accounts.tokensIssued == 1)
        #expect(Set(results).count == 1)
        let new = try #require(results.first ?? nil)
        #expect(try await service.authenticate(accessToken: new.accessToken).updated == nil)
    }

    /// A refresh whose response is held up until two more refreshes have
    /// happened must not drag the session back to its generation.
    @Test func lateRefreshesDoNotMoveTheSessionBack() async throws {
        let store = InMemorySessionStore()
        let (service, accounts) = makeService(store: store)
        let t0 = try await service.signIn(code: accounts.code(for: "ada"), redirectURI: nil).accessToken
        accounts.expire(t0)

        // A refreshes from 0; accounts issues t1, but A's response is stuck.
        let gate = accounts.holdNextRefreshResponse()
        let late = Task { try await service.authenticate(accessToken: t0) }
        await gate.reached.wait()

        // B, with the same t0, gets the same t1 and records it.
        let t1 = try #require(try await service.authenticate(accessToken: t0).updated)
        #expect(t1.version.generation == 1)

        // t1 expires; C refreshes it to t2.
        accounts.expire(t1.accessToken)
        let t2 = try #require(try await service.authenticate(accessToken: t1.accessToken).updated)
        #expect(t2.version.generation == 2)

        // A's response finally arrives. It reports t1, at a version clients rank below t2...
        gate.open()
        let lateResult = try #require(try await late.value.updated)
        #expect(lateResult.accessToken == t1.accessToken)
        #expect(lateResult.version < t2.version)

        // ...and the session stays at t2.
        let session = try #require(try await store.session(forToken: TokenDigest(token: t2.accessToken)))
        #expect(session.generation == 2)
        #expect(try await store.session(forToken: TokenDigest(token: t1.accessToken)) == nil)
        #expect(try await service.authenticate(accessToken: t2.accessToken).updated == nil)
    }

    @Test func staleGenerationsKeepTheSession() async throws {
        let store = InMemorySessionStore()
        let (service, accounts) = makeService(store: store)
        let t0 = try await service.signIn(code: accounts.code(for: "ada"), redirectURI: nil).accessToken
        let atZero = try #require(try await store.session(forToken: TokenDigest(token: t0)))

        // The session moves on twice at accounts...
        accounts.expire(t0)
        let t1 = try #require(try await service.authenticate(accessToken: t0).updated).accessToken
        accounts.expire(t1)
        _ = try #require(try await service.authenticate(accessToken: t1).updated)

        // ...while the store, as a request saw it long ago, still says generation 0.
        let current = try #require(try await store.session(id: atZero.id))
        #expect(try await store.replace(atZero.id, expected: current, with: atZero))

        // accounts answers stale_generation: the token is outdated, not the session over.
        let error = await #expect(throws: AuthenticationError.self) {
            try await service.authenticate(accessToken: t0)
        }
        #expect(error?.code == .invalidAccessToken)
        #expect(try await store.session(id: atZero.id) != nil)
    }

    @Test func revokedSessionsRequireSignIn() async throws {
        let store = InMemorySessionStore()
        let (service, accounts) = makeService(store: store)
        let token = try await service.signIn(code: accounts.code(for: "ada"), redirectURI: nil).accessToken
        accounts.revoke(token)

        let error = await #expect(throws: AuthenticationError.self) {
            try await service.authenticate(accessToken: token)
        }
        #expect(error?.code == .signInRequired)
        #expect(try await store.session(forToken: TokenDigest(token: token)) == nil)
    }

    @Test func accountsBeingDownKeepsTheSession() async throws {
        let (service, accounts) = makeService()
        let token = try await service.signIn(code: accounts.code(for: "ada"), redirectURI: nil).accessToken
        accounts.expire(token)
        accounts.failRefreshes(.unavailable)

        let error = await #expect(throws: AuthenticationError.self) {
            try await service.authenticate(accessToken: token)
        }
        #expect(error?.code == .accountsUnavailable)
        #expect(error?.isRetryable == true)

        accounts.failRefreshes(.none)
        #expect(try await service.authenticate(accessToken: token).updated != nil)
    }

    @Test func unknownTokensAreInvalid() async throws {
        let (service, accounts) = makeService()
        // Issued at accounts, but not through this service's sign-in: no session to refresh.
        let token = accounts.issue()
        #expect(try await service.authenticate(accessToken: token).account.id == "account-1")
        accounts.expire(token)
        let error = await #expect(throws: AuthenticationError.self) {
            try await service.authenticate(accessToken: token)
        }
        #expect(error?.code == .invalidAccessToken)
    }

    @Test func signOutForgetsTheRefreshToken() async throws {
        let (service, accounts) = makeService()
        let token = try await service.signIn(code: accounts.code(for: "ada"), redirectURI: nil).accessToken
        try await service.signOut(accessToken: token)
        accounts.expire(token)
        await #expect(throws: AuthenticationError.self) {
            try await service.authenticate(accessToken: token)
        }
        #expect(accounts.refreshCalls == 0)
    }

    @Test func versionsRoundTripAsText() {
        let version = AccessTokenVersion(signedInAt: 1_794_153_600_000, generation: 3)
        #expect(version.description == "1794153600000.3")
        #expect(AccessTokenVersion("1794153600000.3") == version)
        #expect(AccessTokenVersion("1794153600000") == nil)
        #expect(AccessTokenVersion("a.b") == nil)
        #expect(AccessTokenVersion(signedInAt: 2, generation: 0) > AccessTokenVersion(signedInAt: 1, generation: 9))
    }
}
