import Foundation
import HTTPTypes
public import ProtobufWireCore
import RoutingKit
public import SwiftProtobuf
import Testing
import Vapor
import VaporMacros
import VaporTesting

// A conformance on a public message must be public, hence the `public import`s.
extension Google_Protobuf_StringValue: ProtobufResponseEncodable {}

private let configuration = ProtobufWireConfiguration(
    requestIDHeader: HTTPField.Name("X-Macro-Request-ID")!
)

/// Handlers as a service writes them with VaporMacros: no configuration passed
/// anywhere, messages returned directly or wrapped.
@Controller
struct EchoController {
    @POST("echo")
    func echo(req: Request) async throws -> Google_Protobuf_StringValue {
        let input = try await req.protobuf(Google_Protobuf_StringValue.self)
        guard !input.value.isEmpty else { throw StandardError.invalidArgument("value is required") }
        return Google_Protobuf_StringValue(input.value.uppercased())
    }

    @GET("items", Int.self)
    func item(req: Request, id: Int) async throws -> Protobuf<Google_Protobuf_Int64Value> {
        var headers = HTTPFields()
        headers[HTTPField.Name("X-Item")!] = String(id)
        return Protobuf(Google_Protobuf_Int64Value(Int64(id)), status: .accepted, headers: headers)
    }
}

private func withControllerApp(_ body: (any Client) async throws -> Void) async throws {
    try await withApp(configure: { app in
        app.useProtobufErrors(configuration: configuration)
        try await app.register(collection: EchoController())
    }) { app in
        try await app.testing { client in try await body(client) }
    }
}

@Suite struct MacroTests {
    @Test func returnsMessagesWithTheRequestsConfiguration() async throws {
        try await withControllerApp { client in
            var request = ClientRequest(method: .post, url: "/echo")
            try request.setProtobuf(Google_Protobuf_StringValue("hi"))
            request.headers[configuration.requestIDHeader] = "r-1"
            let response = try await client.send(request)
            #expect(response.status == .ok)
            #expect(response.headers[.contentType] == "application/x-protobuf")
            // The service's request-ID header, though the handler never named it.
            #expect(response.headers[configuration.requestIDHeader] == "r-1")
            #expect(try await response.protobuf(Google_Protobuf_StringValue.self).value == "HI")
        }
    }

    @Test func thrownErrorsAreErrorDetails() async throws {
        try await withControllerApp { client in
            var request = ClientRequest(method: .post, url: "/echo")
            request.headers[configuration.requestIDHeader] = "r-2"
            let response = try await client.send(request)
            #expect(response.status == .badRequest)
            #expect(response.headers[configuration.requestIDHeader] == "r-2")
            let error = await #expect(throws: RemoteServiceError.self) {
                try await response.protobuf(Google_Protobuf_StringValue.self)
            }
            #expect(error?.category == .invalidArgument)
        }
    }

    @Test func wrappedMessagesCarryStatusAndHeaders() async throws {
        try await withControllerApp { client in
            let response = try await client.send(ClientRequest(method: .get, url: "/items/42"))
            #expect(response.status == .accepted)
            #expect(response.headers[HTTPField.Name("X-Item")!] == "42")
            #expect(try await response.protobuf(Google_Protobuf_Int64Value.self).value == 42)
        }
    }

    @Test func outsideARequestTheDefaultApplies() {
        #expect(ProtobufWireConfiguration.current.requestIDHeader == HTTPField.Name("X-Request-ID")!)
        ProtobufWireConfiguration.$current.withValue(configuration) {
            #expect(ProtobufWireConfiguration.current.requestIDHeader == configuration.requestIDHeader)
        }
    }
}
