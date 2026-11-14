import AuthenticationCore
import Foundation
import HTTPTypes
import ProtobufWireCore
import RoutingKit
import SwiftProtobuf
import Testing
import Vapor
import VaporTesting

private struct Boom: Error {}

private func routes(_ app: Application, _ service: AuthenticationService) {
    let authenticated = app.grouped(AuthenticationMiddleware(service: service))
    authenticated.get("me") { req -> String in try req.account.id }
    authenticated.get("fails") { _ -> String in throw StandardError.notFound("nothing here") }
    authenticated.get("crashes") { _ -> String in throw Boom() }

    app.grouped(AuthenticationMiddleware(service: service, requiredScopes: ["notes.write"]))
        .get("scoped") { _ in "ok" }
    app.grouped(AuthenticationMiddleware(service: service, allowsAnonymous: true))
        .get("maybe") { req -> String in (try? req.account.id) ?? "anonymous" }

    // The documented sign-in shape: any body, the token in the headers.
    app.protobufErrors(.post, "auth", "sign-in") { req in
        let code = try req.query.get(String.self, at: "code")
        let signIn = try await service.signIn(code: code, redirectURI: nil)
        return try ProtobufResponse.success(Google_Protobuf_StringValue(signIn.account.id), headers: signIn.responseHeaders)
    }
}

private func get(_ client: some Client, _ path: String, token: String?) async throws -> ClientResponse {
    var request = ClientRequest(method: .get, url: URI(string: path))
    if let token { request.headers.bearerAuthorization = BearerAuthorization(token: token) }
    return try await client.send(request)
}

private func body(_ response: ClientResponse) async throws -> String {
    String(decoding: try await response.body.data(max: .default) ?? Data(), as: UTF8.self)
}

private func authCode(_ response: ClientResponse) async throws -> AuthenticationErrorCode? {
    let error = await #expect(throws: RemoteServiceError.self) {
        try await response.protobuf(WireErrorDetail.self)
    }
    return error?.code(as: AuthenticationErrorCode.self)
}

@Suite struct AuthenticationMiddlewareTests {
    let accounts = FakeAccounts()
    let service: AuthenticationService

    init() {
        service = AuthenticationService(accounts: accounts, store: InMemorySessionStore())
    }

    private func withClient(_ body: (any Client) async throws -> Void) async throws {
        let service = service
        try await withApp(configure: { app in
            app.useProtobufErrors()
            routes(app, service)
        }) { app in
            try await app.testing { client in try await body(client) }
        }
    }

    @Test func authenticatesTheAccount() async throws {
        let token = try await service.signIn(code: accounts.code(for: "ada"), redirectURI: nil).accessToken
        try await withClient { client in
            let response = try await get(client, "/me", token: token)
            #expect(response.status == .ok)
            #expect(try await body(response) == "ada")
            #expect(response.headers[.updatedAccessToken] == nil)
        }
    }

    @Test func missingTokenIsUnauthenticated() async throws {
        try await withClient { client in
            let response = try await get(client, "/me", token: nil)
            #expect(response.status == .unauthorized)
            #expect(response.headers[.wwwAuthenticate] == "Bearer")
            #expect(try await authCode(response) == .missingAccessToken)
        }
    }

    @Test func sendsTheRefreshedToken() async throws {
        let old = try await service.signIn(code: accounts.code(for: "ada"), redirectURI: nil).accessToken
        accounts.expire(old)
        try await withClient { client in
            let response = try await get(client, "/me", token: old)
            #expect(response.status == .ok)
            #expect(try await body(response) == "ada")
            let new = try #require(response.headers[.updatedAccessToken])
            #expect(new != old)
            let version = try #require(response.headers[.updatedAccessTokenVersion].flatMap(AccessTokenVersion.init))
            #expect(version.generation == 1)
            #expect(response.headers[.cacheControl] == "no-store")

            let stale = try await get(client, "/me", token: old)
            #expect(stale.status == .unauthorized)
            #expect(stale.headers[.wwwAuthenticate] == #"Bearer error="invalid_token""#)
            #expect(stale.headers[.authenticationError] == "invalid_access_token")
            #expect(try await authCode(stale) == .invalidAccessToken)

            #expect(try await get(client, "/me", token: new).status == .ok)
        }
    }

    @Test func errorResponsesStillCarryTheRefreshedToken() async throws {
        let first = try await service.signIn(code: accounts.code(for: "ada"), redirectURI: nil).accessToken
        accounts.expire(first)
        try await withClient { client in
            let failed = try await get(client, "/fails", token: first)
            #expect(failed.status == .notFound)
            let second = try #require(failed.headers[.updatedAccessToken])

            accounts.expire(second)
            let crashed = try await get(client, "/crashes", token: second)
            #expect(crashed.status == .internalServerError)
            #expect(crashed.headers[.updatedAccessToken] != nil)
            #expect(crashed.headers[.updatedAccessTokenVersion]?.hasSuffix(".2") == true)
        }
    }

    @Test func revokedSessionMeansSignIn() async throws {
        let token = try await service.signIn(code: accounts.code(for: "ada"), redirectURI: nil).accessToken
        accounts.revoke(token)
        try await withClient { client in
            let response = try await get(client, "/me", token: token)
            #expect(response.status == .unauthorized)
            #expect(response.headers[.authenticationError] == "sign_in_required")
            #expect(try await authCode(response) == .signInRequired)
        }
    }

    @Test func requiresScopes() async throws {
        let token = try await service.signIn(code: accounts.code(for: "ada"), redirectURI: nil).accessToken
        try await withClient { client in
            let response = try await get(client, "/scoped", token: token)
            #expect(response.status == .forbidden)
            #expect(response.headers[.wwwAuthenticate]?.contains(#"scope="notes.write""#) == true)
            #expect(try await authCode(response) == .insufficientScope)
        }
    }

    @Test func signInSendsTheTokenInHeaders() async throws {
        let code = accounts.code(for: "ada")
        try await withClient { client in
            let response = try await client.send(ClientRequest(method: .post, url: URI(string: "/auth/sign-in?code=\(code)")))
            #expect(response.status == .ok)
            let token = try #require(response.headers[.updatedAccessToken])
            #expect(response.headers[.updatedAccessTokenVersion].flatMap(AccessTokenVersion.init)?.generation == 0)
            #expect(try await response.protobuf(Google_Protobuf_StringValue.self).value == "ada")
            let me = try await get(client, "/me", token: token)
            #expect(try await body(me) == "ada")

            let reused = try await client.send(ClientRequest(method: .post, url: URI(string: "/auth/sign-in?code=\(code)")))
            #expect(reused.status == .badRequest)
            #expect(reused.headers[.authenticationError] == "invalid_authorization_code")
        }
    }

    @Test func anonymousRoutes() async throws {
        let token = try await service.signIn(code: accounts.code(for: "ada"), redirectURI: nil).accessToken
        try await withClient { client in
            let anonymous = try await get(client, "/maybe", token: nil)
            #expect(try await body(anonymous) == "anonymous")
            let signedIn = try await get(client, "/maybe", token: token)
            #expect(try await body(signedIn) == "ada")
            let bogus = try await get(client, "/maybe", token: "bogus")
            #expect(bogus.status == .unauthorized)
        }
    }
}
