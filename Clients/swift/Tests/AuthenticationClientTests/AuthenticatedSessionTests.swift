import AuthenticationClient
import Foundation
import Testing

private let v0 = AccessTokenVersion(signedInAt: 1_794_153_600_000, generation: 0)
private let v1 = AccessTokenVersion(signedInAt: 1_794_153_600_000, generation: 1)
private let v2 = AccessTokenVersion(signedInAt: 1_794_153_600_000, generation: 2)

private func request(_ host: String) -> URLRequest {
    var request = URLRequest(url: URL(string: "https://\(host)/v1/notes")!)
    request.httpMethod = "POST"
    request.httpBody = Data("body".utf8)
    return request
}

@Suite struct AuthenticatedSessionTests {
    @Test func storesUpdatedTokensButNeverOlderOnes() async throws {
        let storage = InMemoryAccessTokenStorage(StoredAccessToken(accessToken: "a", version: v0))
        let (urlSession, host) = StubServer.session { request in
            request.bearer == "a"
                ? (200, ["X-Updated-Access-Token": "b", "X-Updated-Access-Token-Version": v1.description])
                : (200, ["X-Updated-Access-Token": "a-again", "X-Updated-Access-Token-Version": v0.description])
        }
        let session = AuthenticatedSession(storage: storage, urlSession: urlSession)

        _ = try await session.data(for: request(host))
        #expect(try storage.current() == StoredAccessToken(accessToken: "b", version: v1))
        // A late response carrying an older token does not replace the newer one.
        _ = try await session.data(for: request(host))
        #expect(try storage.current()?.accessToken == "b")
    }

    @Test func retriesWithANewerStoredToken() async throws {
        let storage = InMemoryAccessTokenStorage(StoredAccessToken(accessToken: "a", version: v0))
        let (urlSession, host) = StubServer.session { request in
            guard request.bearer == "b" else {
                // Another request refreshed "a" meanwhile and its response has been stored.
                try storage.offer(StoredAccessToken(accessToken: "b", version: v1))
                return (401, invalidToken)
            }
            #expect(request.bodyData == Data("body".utf8))
            return (200, [:])
        }
        let (_, response) = try await AuthenticatedSession(storage: storage, urlSession: urlSession).data(for: request(host))
        #expect(response.statusCode == 200)
    }

    @Test func waitsForATokenStillInFlight() async throws {
        let storage = InMemoryAccessTokenStorage(StoredAccessToken(accessToken: "a", version: v0))
        let (urlSession, host) = StubServer.session { request in
            request.bearer == "b" ? (200, [:]) : (401, invalidToken)
        }
        // The response carrying "b" arrives after this request's error.
        Task {
            try await Task.sleep(for: .milliseconds(200))
            try storage.offer(StoredAccessToken(accessToken: "b", version: v1))
        }
        let session = AuthenticatedSession(storage: storage, urlSession: urlSession, newTokenTimeout: .seconds(5))
        let started = ContinuousClock.now
        let (_, response) = try await session.data(for: request(host))
        #expect(response.statusCode == 200)
        #expect(ContinuousClock.now - started >= .milliseconds(150))
    }

    @Test func givesUpWhenNoNewerTokenArrives() async throws {
        let storage = InMemoryAccessTokenStorage(StoredAccessToken(accessToken: "a", version: v0))
        let (urlSession, host) = StubServer.session { _ in (401, invalidToken) }
        let session = AuthenticatedSession(storage: storage, urlSession: urlSession, newTokenTimeout: .milliseconds(200))
        await #expect(throws: AuthenticationClientError.signInRequired) {
            try await session.data(for: request(host))
        }
        #expect(try storage.current() == nil)
    }

    @Test func endedSessionsKeepANewerSignIn() async throws {
        let newer = StoredAccessToken(accessToken: "fresh", version: AccessTokenVersion(signedInAt: v0.signedInAt + 1, generation: 0))
        let storage = InMemoryAccessTokenStorage(StoredAccessToken(accessToken: "a", version: v0))
        let (urlSession, host) = StubServer.session { _ in
            // Another process signed in again while this request was out.
            try storage.offer(newer)
            return (401, ["X-Authentication-Error": "sign_in_required"])
        }
        await #expect(throws: AuthenticationClientError.signInRequired) {
            try await AuthenticatedSession(storage: storage, urlSession: urlSession).data(for: request(host))
        }
        #expect(try storage.current() == newer)
    }

    @Test func otherErrorsAreReturned() async throws {
        let storage = InMemoryAccessTokenStorage(StoredAccessToken(accessToken: "a", version: v0))
        let (urlSession, host) = StubServer.session { _ in (503, ["X-Authentication-Error": "accounts_unavailable"]) }
        let (_, response) = try await AuthenticatedSession(storage: storage, urlSession: urlSession).data(for: request(host))
        #expect(response.statusCode == 503)
        #expect(try storage.current()?.accessToken == "a")
    }

    @Test func notSignedIn() async throws {
        let (urlSession, host) = StubServer.session { _ in (200, [:]) }
        await #expect(throws: AuthenticationClientError.notSignedIn) {
            try await AuthenticatedSession(storage: InMemoryAccessTokenStorage(), urlSession: urlSession).data(for: request(host))
        }
    }

    @Test func signInStoresTheTokenFromTheHeaders() async throws {
        let storage = InMemoryAccessTokenStorage()
        let (urlSession, host) = StubServer.session { request in
            #expect(request.bearer == nil)
            return (200, ["X-Updated-Access-Token": "t0", "X-Updated-Access-Token-Version": v0.description])
        }
        let session = AuthenticatedSession(storage: storage, urlSession: urlSession)
        let (_, response) = try await session.signIn(with: request(host))
        #expect(response.statusCode == 200)
        #expect(try storage.current() == StoredAccessToken(accessToken: "t0", version: v0))

        try await session.signOut()
        #expect(try storage.current() == nil)
    }

    @Test func failedSignInsStoreNothing() async throws {
        let storage = InMemoryAccessTokenStorage()
        let (failing, failingHost) = StubServer.session { _ in (400, [:]) }
        let (_, response) = try await AuthenticatedSession(storage: storage, urlSession: failing).signIn(with: request(failingHost))
        #expect(response.statusCode == 400)

        let (headerless, headerlessHost) = StubServer.session { _ in (200, [:]) }
        await #expect(throws: AuthenticationClientError.missingToken) {
            try await AuthenticatedSession(storage: storage, urlSession: headerless).signIn(with: request(headerlessHost))
        }
        #expect(try storage.current() == nil)
    }

    @Test func versions() {
        #expect(AccessTokenVersion("1794153600000.3") == AccessTokenVersion(signedInAt: 1_794_153_600_000, generation: 3))
        #expect(AccessTokenVersion("garbage") == nil)
        #expect(v2 > v1)
        #expect(AccessTokenVersion(signedInAt: 2, generation: 0) > AccessTokenVersion(signedInAt: 1, generation: 7))
    }
}
