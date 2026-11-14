import AuthenticationCore
import Foundation
import HTTPTypes
import RoutingKit
import Testing
import Vapor
import VaporTesting

/// The shape of accounts' `/token` and `/introspect` requests, decoded the way
/// accounts decodes them (Vapor content, form-encoded).
private struct TokenForm: Content {
    let grant_type: String
    let refresh_token: String?
    let code: String?
    let redirect_uri: String?
    let expected_generation: UInt64?
    let client_id: String
    let client_secret: String
}

private struct IntrospectForm: Content {
    let token: String
    let token_type_hint: String?
    let client_id: String
    let client_secret: String
}

private func fakeAccounts(_ app: Application) {
    app.post("v1", "token") { req -> Response in
        let form = try await req.content.decode(TokenForm.self)
        guard form.client_id == "notes", form.client_secret == "s3cret &=+" else {
            return try await errorResponse(req, .unauthorized, "invalid_client")
        }
        switch (form.grant_type, form.refresh_token, form.code) {
        case ("refresh_token", "good refresh", _) where form.expected_generation == 4:
            return try await json(req, #"{"access_token":"new","token_type":"Bearer","expires_in":3600,"refresh_token":"good refresh","scope":"user.read group.read","access_token_generation":5}"#)
        case ("refresh_token", "good refresh", _):
            return try await errorResponse(req, .badRequest, "stale_generation")
        case ("authorization_code", _, "good code"):
            return try await json(req, #"{"access_token":"new","token_type":"Bearer","expires_in":3600,"refresh_token":"good refresh","scope":"user.read group.read","access_token_generation":0}"#)
        case ("refresh_token", "boom", _):
            return Response(status: .badGateway)
        default:
            return try await errorResponse(req, .badRequest, "invalid_grant")
        }
    }
    app.post("v1", "introspect") { req -> Response in
        let form = try await req.content.decode(IntrospectForm.self)
        #expect(form.token_type_hint == "access_token")
        if form.token == "live" {
            return try await json(req, #"{"active":true,"scope":"user.read","client_id":"notes","token_type":"Bearer","exp":2000000000,"sub":"ada","access_token_generation":3}"#)
        }
        return try await json(req, #"{"active":false}"#)
    }
}

private func json(_ req: Request, _ body: String, status: HTTPResponse.Status = .ok) async throws -> Response {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    return Response(status: status, headers: headers, body: .init(string: body))
}

private func errorResponse(_ req: Request, _ status: HTTPResponse.Status, _ code: String) async throws -> Response {
    try await json(req, #"{"error":"\#(code)","error_description":"nope"}"#, status: status)
}

@Suite struct HTTPAccountsOAuthClientTests {
    private func withAccounts(secret: String = "s3cret &=+", _ body: (HTTPAccountsOAuthClient) async throws -> Void) async throws {
        try await withApp(configure: { fakeAccounts($0) }) { app in
            try await app.testing { client in
                let configuration = AccountsConfiguration(
                    clientIdentifier: "notes", clientSecret: secret,
                    frontendURL: URL(string: "https://accounts.example")!,
                    apiURL: URL(string: "http://localhost/v1")!
                )
                try await body(HTTPAccountsOAuthClient(configuration: configuration, client: client))
            }
        }
    }

    @Test func introspects() async throws {
        try await withAccounts { accounts in
            let live = try await accounts.introspect(accessToken: "live")
            #expect(live.active && live.subject == "ada" && live.scopes == ["user.read"])
            #expect(live.expiresAt == Date(timeIntervalSince1970: 2_000_000_000))
            #expect(live.generation == 3)
            #expect(try await accounts.introspect(accessToken: "dead") == .inactive)
        }
    }

    @Test func refreshesAndExchanges() async throws {
        try await withAccounts { accounts in
            let refreshed = try await accounts.refresh(refreshToken: "good refresh", expectedGeneration: 4)
            #expect(refreshed == TokenGrant(
                accessToken: "new", expiresIn: 3600, refreshToken: "good refresh",
                scopes: ["user.read", "group.read"], generation: 5
            ))
            let exchanged = try await accounts.exchange(code: "good code", redirectURI: "notes://signed-in")
            #expect(exchanged.accessToken == "new")
            #expect(exchanged.generation == 0)
        }
    }

    @Test func classifiesFailures() async throws {
        try await withAccounts { accounts in
            let rejected = await #expect(throws: AccountsOAuthError.self) {
                try await accounts.refresh(refreshToken: "revoked", expectedGeneration: 0)
            }
            #expect(rejected?.isInvalidGrant == true)

            let stale = await #expect(throws: AccountsOAuthError.self) {
                try await accounts.refresh(refreshToken: "good refresh", expectedGeneration: 1)
            }
            #expect(stale?.isStaleGeneration == true)
            #expect(stale?.isInvalidGrant == false)

            let down = await #expect(throws: AccountsOAuthError.self) {
                try await accounts.refresh(refreshToken: "boom", expectedGeneration: 0)
            }
            #expect(down?.isInvalidGrant == false)
            #expect(down?.isStaleGeneration == false)
        }
        try await withAccounts(secret: "wrong") { accounts in
            let error = await #expect(throws: AccountsOAuthError.self) {
                try await accounts.refresh(refreshToken: "good refresh", expectedGeneration: 4)
            }
            #expect(error?.isInvalidGrant == false)
        }
    }
}
