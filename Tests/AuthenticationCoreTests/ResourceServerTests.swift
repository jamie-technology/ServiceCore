import AuthenticationCore
import Foundation
import HTTPTypes
import ProtobufWireCore
import RoutingKit
import Testing
import Vapor
import VaporTesting

// A service that provides an API (RFC 8707): other services' clients call it with tokens accounts issued for that API,
// either for a person (delegated) or as themselves (client credentials).

private let resource = "https://groups.example/api"

@Suite struct ResourceServerTests {
    let accounts = FakeAccounts()

    func service(resourceIdentifier: String? = resource) -> AuthenticationService {
        AuthenticationService(accounts: accounts, store: InMemorySessionStore(), resourceIdentifier: resourceIdentifier)
    }

    @Test func delegatedTokenIsThePersonThroughTheClient() async throws {
        let token = accounts.issueForAPI(resource, client: "dauntless", subject: "alice", scopes: ["groups.read"])
        let principal = try await service().authenticatePrincipal(accessToken: token).principal
        guard case .account(let account) = principal else { Issue.record("not an account: \(principal)"); return }
        #expect(account.id == "alice")
        #expect(account.client == "dauntless")
        #expect(principal.subject == "account:alice")
        #expect(principal.scopes == ["groups.read"])
    }

    @Test func clientCredentialsTokenIsTheService() async throws {
        let token = accounts.issueForAPI(resource, client: "dauntless", subject: nil, scopes: ["groups.read"])
        let principal = try await service().authenticatePrincipal(accessToken: token).principal
        #expect(principal == .service(AuthenticatedService(clientIdentifier: "dauntless", scopes: ["groups.read"], accessToken: token)))
        #expect(principal.subject == "service:dauntless")
    }

    @Test func ownSignInIsStillThePersonWithNoClient() async throws {
        let token = accounts.issue(subject: "bob")
        let principal = try await service().authenticatePrincipal(accessToken: token).principal
        #expect(principal == .account(AuthenticatedAccount(subject: "bob", scopes: ["user.read"], accessToken: token)))
    }

    @Test func otherAudiencesAreRefused() async throws {
        let elsewhere = accounts.issueForAPI("https://elsewhere.example", client: "dauntless", subject: "alice", scopes: [])
        await #expect(throws: AuthenticationError.self) { try await service().authenticatePrincipal(accessToken: elsewhere) }
        // A service that provides no API accepts no API tokens.
        let ours = accounts.issueForAPI(resource, client: "dauntless", subject: "alice", scopes: [])
        await #expect(throws: AuthenticationError.self) { try await service(resourceIdentifier: nil).authenticatePrincipal(accessToken: ours) }
    }

    @Test func authenticateStillOnlyAcceptsPeople() async throws {
        let token = accounts.issueForAPI(resource, client: "dauntless", subject: nil, scopes: [])
        await #expect(throws: AuthenticationError.self) { try await service().authenticate(accessToken: token) }
        let delegated = accounts.issueForAPI(resource, client: "dauntless", subject: "alice", scopes: [])
        let authentication = try await service().authenticate(accessToken: delegated)
        #expect(authentication.account.client == "dauntless")
    }

    // MARK: Middleware

    private func withClient(_ body: (any Client) async throws -> Void) async throws {
        let service = service()
        try await withApp(configure: { app in
            app.useProtobufErrors()
            app.grouped(AuthenticationMiddleware(service: service))
                .get("people") { req -> String in try req.principal.subject }
            app.grouped(AuthenticationMiddleware(service: service, requiredScopes: ["groups.read"], acceptsServices: true))
                .get("anyone") { req -> String in try req.principal.subject }
        }) { app in
            try await app.testing { client in try await body(client) }
        }
    }

    private func get(_ client: some Client, _ path: String, token: String) async throws -> ClientResponse {
        var request = ClientRequest(method: .get, url: URI(string: path))
        request.headers.bearerAuthorization = BearerAuthorization(token: token)
        return try await client.send(request)
    }

    @Test func servicesOnlyWhereRoutesAcceptThem() async throws {
        let serviceToken = accounts.issueForAPI(resource, client: "dauntless", subject: nil, scopes: ["groups.read"])
        let delegated = accounts.issueForAPI(resource, client: "dauntless", subject: "alice", scopes: ["groups.read"])
        try await withClient { client in
            let refused = try await get(client, "/people", token: serviceToken)
            #expect(refused.status == .unauthorized)
            let person = try await get(client, "/people", token: delegated)
            #expect(String(decoding: try await person.body.data(max: .default) ?? Data(), as: UTF8.self) == "account:alice")

            let service = try await get(client, "/anyone", token: serviceToken)
            #expect(service.status == .ok)
            #expect(String(decoding: try await service.body.data(max: .default) ?? Data(), as: UTF8.self) == "service:dauntless")
        }
    }

    @Test func scopesApplyToServicesToo() async throws {
        let unscoped = accounts.issueForAPI(resource, client: "dauntless", subject: nil, scopes: [])
        try await withClient { client in
            let response = try await get(client, "/anyone", token: unscoped)
            #expect(response.status == .forbidden)
        }
    }
}
