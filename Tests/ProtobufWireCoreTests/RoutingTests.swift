import Foundation
import HTTPTypes
import ProtobufWireCore
import RoutingKit
import SwiftProtobuf
import Testing
import Vapor
import VaporTesting

private struct Boom: Error {}

private let configuration = ProtobufWireConfiguration(
    requestIDHeader: HTTPField.Name("X-Test-Request-ID")!
)

/// Uses well-known types as request and response messages, so the tests need
/// no protos of their own.
private func routes(_ app: Application) {
    app.protobuf("echo", configuration: configuration) { (input: Google_Protobuf_StringValue, _) in
        Google_Protobuf_StringValue(input.value.uppercased())
    }
    app.protobuf("missing", configuration: configuration) { (_: Google_Protobuf_Empty, _) -> Google_Protobuf_Empty in
        throw StandardError.notFound("nothing here")
    }
    app.protobuf("mail", configuration: configuration) { (_: Google_Protobuf_Empty, _) -> Google_Protobuf_Empty in
        throw ServiceError(MailErrorCode.mailboxFull, "mailbox full")
    }
    app.protobuf("boom", configuration: configuration) { (_: Google_Protobuf_Empty, _) -> Google_Protobuf_Empty in
        throw Boom()
    }
    app.protobuf("abort", configuration: configuration) { (_: Google_Protobuf_Empty, _) -> Google_Protobuf_Empty in
        throw Abort(.contentTooLarge, reason: "too big")
    }
}

private func call(
    _ client: some Client, _ path: String, body: some SwiftProtobuf.Message, requestID: String? = nil
) async throws -> ClientResponse {
    var request = ClientRequest(method: .post, url: URI(string: path))
    try request.setProtobuf(body)
    if let requestID { request.headers[configuration.requestIDHeader] = requestID }
    return try await client.send(request)
}

@Suite struct RoutingTests {
    @Test func successDecodesAndEncodes() async throws {
        try await withApp(configure: { routes($0) }) { app in
            try await app.testing { client in
                let response = try await call(client, "/echo", body: Google_Protobuf_StringValue("hi"), requestID: "abc")
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "application/x-protobuf")
                #expect(response.headers[configuration.requestIDHeader] == "abc")
                let decoded = try await response.protobuf(Google_Protobuf_StringValue.self)
                #expect(decoded.value == "HI")
            }
        }
    }

    @Test func emptyBodyIsTheDefaultMessage() async throws {
        try await withApp(configure: { routes($0) }) { app in
            try await app.testing { client in
                let response = try await client.send(ClientRequest(method: .post, url: "/echo"))
                #expect(response.status == .ok)
                #expect(try await response.protobuf(Google_Protobuf_StringValue.self).value == "")
            }
        }
    }

    @Test func undecodableBodyIsInvalidArgument() async throws {
        try await withApp(configure: { routes($0) }) { app in
            try await app.testing { client in
                var request = ClientRequest(method: .post, url: "/echo")
                request.body = .init(data: Data([0xFF, 0xFF, 0xFF]))
                let response = try await client.send(request)
                #expect(response.status == .badRequest)
                let error = await #expect(throws: RemoteServiceError.self) {
                    try await response.protobuf(Google_Protobuf_StringValue.self)
                }
                #expect(error?.category == .invalidArgument)
            }
        }
    }

    @Test func standardErrorsAreErrorDetails() async throws {
        try await withApp(configure: { routes($0) }) { app in
            try await app.testing { client in
                let response = try await call(client, "/missing", body: Google_Protobuf_Empty())
                #expect(response.status == .notFound)
                #expect(response.headers[configuration.requestIDHeader] != nil)
                let error = await #expect(throws: RemoteServiceError.self) {
                    try await response.protobuf(Google_Protobuf_Empty.self)
                }
                #expect(error?.detail?.message == "nothing here")
                #expect(error?.category == .notFound)
            }
        }
    }

    @Test func serviceCodesSurviveTheTrip() async throws {
        try await withApp(configure: { routes($0) }) { app in
            try await app.testing { client in
                let response = try await call(client, "/mail", body: Google_Protobuf_Empty())
                #expect(response.status == .tooManyRequests)
                let error = await #expect(throws: RemoteServiceError.self) {
                    try await response.protobuf(Google_Protobuf_Empty.self)
                }
                #expect(error?.code(as: MailErrorCode.self) == .mailboxFull)
                #expect(error?.isRetryable == true)
            }
        }
    }

    @Test func unexpectedErrorsDoNotLeak() async throws {
        try await withApp(configure: { routes($0) }) { app in
            try await app.testing { client in
                let response = try await call(client, "/boom", body: Google_Protobuf_Empty())
                #expect(response.status == .internalServerError)
                let error = await #expect(throws: RemoteServiceError.self) {
                    try await response.protobuf(Google_Protobuf_Empty.self)
                }
                #expect(error?.detail?.message == "internal error")
                #expect(error?.detail?.message.contains("Boom") == false)
            }
        }
    }

    @Test func abortKeepsItsStatus() async throws {
        try await withApp(configure: { routes($0) }) { app in
            try await app.testing { client in
                let response = try await call(client, "/abort", body: Google_Protobuf_Empty())
                #expect(response.status == .contentTooLarge)
                let error = await #expect(throws: RemoteServiceError.self) {
                    try await response.protobuf(Google_Protobuf_Empty.self)
                }
                #expect(error?.category == .invalidArgument)
                #expect(error?.detail?.message == "too big")
            }
        }
    }

    @Test func middlewareCatchesPlainRoutes() async throws {
        try await withApp(configure: { app in
            app.useProtobufErrors(configuration: configuration)
            app.get("plain") { _ -> String in throw StandardError.permissionDenied("no") }
        }) { app in
            try await app.testing { client in
                let response = try await client.get("/plain")
                #expect(response.status == .forbidden)
                let error = await #expect(throws: RemoteServiceError.self) {
                    try await response.protobuf(Google_Protobuf_Empty.self)
                }
                #expect(error?.category == .permissionDenied)
            }
        }
    }

    @Test func translatorRunsFirst() {
        let translating = ProtobufWireConfiguration(translateError: { error in
            error is Boom ? StandardError.unavailable("translated") : nil
        })
        let converted = ProtobufResponse.convert(Boom(), configuration: translating)
        #expect(converted.status == .serviceUnavailable)
    }
}
