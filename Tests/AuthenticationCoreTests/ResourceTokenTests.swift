import AuthenticationCore
import Foundation
import ProtobufWireCore
import Testing

// A service calling another service's API as the person signed in to it (multi-resource sign-in, RFC 8707).

private let groups = "https://groups.example/api"

@Suite struct ResourceTokenTests {
    let accounts = FakeAccounts()
    let service: AuthenticationService

    init() {
        service = AuthenticationService(accounts: accounts, store: InMemorySessionStore())
    }

    func signIn(resources: [String] = [groups]) async throws -> String {
        try await service.signIn(code: accounts.code(for: "alice", resources: resources), redirectURI: nil).accessToken
    }

    @Test func tokenForTheResourceIsCached() async throws {
        let session = try await signIn()
        let first = try await service.resourceToken(groups, forSessionOf: session)
        #expect(first.resource == groups)
        #expect(first.generation == 0)
        let again = try await service.resourceToken(groups, forSessionOf: session)
        #expect(again == first)
        #expect(accounts.resourceRefreshCalls == 1)
    }

    @Test func replacingARefusedTokenGetsTheNextOnceForEveryone() async throws {
        let session = try await signIn()
        let first = try await service.resourceToken(groups, forSessionOf: session)
        let replacements = try await withThrowingTaskGroup(of: ResourceToken.self) { group in
            for _ in 0..<5 { group.addTask { try await service.resourceToken(groups, forSessionOf: session, replacing: first) } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(Set(replacements.map(\.accessToken)).count == 1)
        #expect(replacements.allSatisfy { $0.generation == 1 })
    }

    @Test func resourcesTheSignInDoesntCoverAreNotGranted() async throws {
        let session = try await signIn(resources: [])
        let error = await #expect(throws: AuthenticationError.self) {
            try await service.resourceToken(groups, forSessionOf: session)
        }
        #expect(error?.code == .resourceNotGranted)
    }

    @Test func aRevokedGrantMeansSigningInAgain() async throws {
        let session = try await signIn()
        accounts.revoke(session)
        let error = await #expect(throws: AuthenticationError.self) {
            try await service.resourceToken(groups, forSessionOf: session)
        }
        #expect(error?.code == .signInRequired)
    }

    @Test func unknownSessionsAreRefused() async throws {
        let error = await #expect(throws: AuthenticationError.self) {
            try await service.resourceToken(groups, forSessionOf: "no-such-token")
        }
        #expect(error?.code == .invalidAccessToken)
    }

    @Test func authorizationURLAsksForEveryResource() throws {
        let configuration = AccountsConfiguration(
            clientIdentifier: "dauntless", clientSecret: "s",
            frontendURL: URL(string: "https://accounts.example")!, apiURL: URL(string: "https://api.accounts.example")!
        )
        let url = configuration.authorizationURL(redirectURI: "https://dauntless.example/cb", scopes: ["user.read", "groups.read"], state: "x", resources: [groups, "https://ledger.example"])
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.filter { $0.name == "resource" }.compactMap(\.value) == [groups, "https://ledger.example"])
    }
}
