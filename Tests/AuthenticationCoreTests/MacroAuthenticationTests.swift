import AuthenticationCore
import Foundation
import HTTPTypes
import ProtobufWireCore
import RoutingKit
import SwiftProtobuf
import Testing
import Vapor
import VaporMacros
import VaporTesting

/// An authenticated controller written with VaporMacros.
@Controller
struct AccountController {
    let auth: AuthenticationService

    @GET("v1", "me")
    @AuthMiddleware(AuthenticatedAccount.self, using: { (controller: AccountController) in
        AuthenticationMiddleware(service: controller.auth)
    })
    func me(req: Request, account: AuthenticatedAccount) async throws -> Protobuf<Google_Protobuf_StringValue> {
        Protobuf(Google_Protobuf_StringValue(account.id))
    }

    @POST("v1", "fails")
    @AuthMiddleware(AuthenticatedAccount.self, using: { (controller: AccountController) in
        AuthenticationMiddleware(service: controller.auth)
    })
    func fails(req: Request, account: AuthenticatedAccount) async throws -> Protobuf<Google_Protobuf_StringValue> {
        throw StandardError.notFound("nothing for \(account.id)")
    }
}

@Suite struct MacroAuthenticationTests {
    let accounts = FakeAccounts()
    let service: AuthenticationService

    init() {
        service = AuthenticationService(accounts: accounts, store: InMemorySessionStore())
    }

    private func get(_ client: some Client, _ path: String, token: String, method: HTTPRequest.Method = .get) async throws -> ClientResponse {
        var request = ClientRequest(method: method, url: URI(string: path))
        request.headers.bearerAuthorization = BearerAuthorization(token: token)
        return try await client.send(request)
    }

    @Test func authenticatesAndRefreshes() async throws {
        let token = try await service.signIn(code: accounts.code(for: "ada"), redirectURI: nil).accessToken
        let service = service
        try await withApp(configure: { app in
            app.useProtobufErrors(configuration: ProtobufWireConfiguration(requestIDHeader: HTTPField.Name("X-Notes-Request-ID")!))
            try await app.register(collection: AccountController(auth: service))
        }) { app in
            try await app.testing { client in
                let response = try await get(client, "/v1/me", token: token)
                #expect(response.status == .ok)
                #expect(try await response.protobuf(Google_Protobuf_StringValue.self).value == "ada")

                // Refreshed inside a macro route; the error comes back in the service's
                // configuration, and still carries the new token.
                accounts.expire(token)
                let failed = try await get(client, "/v1/fails", token: token, method: .post)
                #expect(failed.status == .notFound)
                #expect(failed.headers[.updatedAccessToken] != nil)
                #expect(failed.headers[HTTPField.Name("X-Notes-Request-ID")!] != nil)

                let stale = try await get(client, "/v1/me", token: token)
                #expect(stale.headers[.authenticationError] == "invalid_access_token")
            }
        }
    }
}
