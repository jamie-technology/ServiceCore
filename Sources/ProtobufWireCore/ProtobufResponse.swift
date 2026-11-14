import Foundation
public import HTTPTypes
public import Logging
public import SwiftProtobuf
public import Vapor

// The protobuf-over-HTTP bridge.
//
// Vapor's `Content` is Codable-based, which protobuf messages are not. Rather
// than bending one to the other, requests and responses are read and written
// directly: the wire format is protobuf and nothing here pretends otherwise.

/// How a service speaks protobuf over HTTP.
public struct ProtobufWireConfiguration: Sendable {
    /// The header a request ID arrives in and is echoed back in, so a call
    /// can be correlated across the client's logs and ours.
    public var requestIDHeader: HTTPField.Name

    /// The `Content-Type` of every protobuf body.
    public var contentType: String

    /// Turns errors this package does not know about into wire errors, e.g.
    /// mapping the Record Layer's `versionMismatch` to a conflict. Consulted
    /// before the built-in mapping; return `nil` to fall through to it.
    public var translateError: (@Sendable (any Error) -> (any ProtobufErrorConvertible)?)?

    public init(
        requestIDHeader: HTTPField.Name = HTTPField.Name("X-Request-ID")!,
        contentType: String = "application/x-protobuf",
        translateError: (@Sendable (any Error) -> (any ProtobufErrorConvertible)?)? = nil
    ) {
        self.requestIDHeader = requestIDHeader
        self.contentType = contentType
        self.translateError = translateError
    }

    public static var `default`: ProtobufWireConfiguration { ProtobufWireConfiguration() }

    /// The configuration of the request being handled.
    ///
    /// Every helper here defaults to it, so a handler (above all one written
    /// with VaporMacros' `@Controller`, which has nowhere to pass one) never
    /// names a configuration. ``ProtobufErrorMiddleware`` (installed by
    /// `app.useProtobufErrors(configuration:)`) sets it for each request, as do
    /// the `protobuf` route helpers when given one. Outside a request it is
    /// ``default``.
    @TaskLocal public static var current = ProtobufWireConfiguration()
}

/// Builds protobuf success and failure responses.
public enum ProtobufResponse {
    /// `message` as an HTTP response.
    public static func success(
        _ message: some SwiftProtobuf.Message,
        status: HTTPResponse.Status = .ok,
        headers: HTTPFields = [:],
        requestID: String? = nil,
        configuration: ProtobufWireConfiguration = .current
    ) throws -> Response {
        try encode(
            message, status: status, headers: headers,
            requestID: requestID, configuration: configuration
        )
    }

    /// Any thrown error, as the client should see it. Never throws: a failure
    /// to report a failure must not turn into a different one.
    ///
    /// Errors that are the client's to handle (``ProtobufErrorConvertible``,
    /// Vapor's `AbortError`, an undecodable body) are sent as they are.
    /// Anything else is ours: it is logged in full, and the client gets an
    /// opaque internal error and the request ID to quote.
    public static func failure(
        _ error: any Error,
        requestID: String? = nil,
        configuration: ProtobufWireConfiguration = .current,
        logger: Logger = Logger.current
    ) -> Response {
        let wireError = convert(error, configuration: configuration)
        var metadata: Logger.Metadata = ["error": .string(wireError.logDescription)]
        if let requestID { metadata["requestID"] = .string(requestID) }

        if wireError is UnexpectedError {
            logger.error("request failed", metadata: metadata.merging(
                ["underlying": .string(String(reflecting: error))], uniquingKeysWith: { $1 }
            ))
        } else if wireError.status.code >= 500 {
            logger.error("request failed", metadata: metadata)
        } else {
            logger.info("request rejected", metadata: metadata)
        }

        do {
            return try encode(
                wireError.body, status: wireError.status, headers: wireError.responseHeaders,
                requestID: requestID, configuration: configuration
            )
        } catch {
            // Serialising an error body cannot realistically fail, but if it
            // does the status still tells the client what happened.
            var headers = HTTPFields()
            if let requestID { headers[configuration.requestIDHeader] = requestID }
            return Response(status: wireError.status, headers: headers)
        }
    }

    /// The wire form of any error, without building a response.
    public static func convert(
        _ error: any Error, configuration: ProtobufWireConfiguration = .current
    ) -> any ProtobufErrorConvertible {
        if let translated = configuration.translateError?(error) {
            return translated
        }
        switch error {
        case let error as any ProtobufErrorConvertible:
            return error
        case is BinaryDecodingError, is JSONDecodingError:
            return StandardError.invalidArgument("the request body is not a valid protobuf message")
        case is CancellationError:
            return StandardError.cancelled("the request was cancelled")
        case let abort as any AbortError:
            // Keeps Vapor's own status (413 for an oversized body, say) rather
            // than flattening it to the category's.
            return StatusError(
                status: abort.status, headers: abort.headers,
                error: StandardError(WireErrorCode(status: abort.status), abort.reason)
            )
        default:
            return UnexpectedError()
        }
    }

    private static func encode(
        _ message: any SwiftProtobuf.Message,
        status: HTTPResponse.Status,
        headers extra: HTTPFields,
        requestID: String?,
        configuration: ProtobufWireConfiguration
    ) throws -> Response {
        var headers = extra
        headers[.contentType] = configuration.contentType
        if let requestID {
            headers[configuration.requestIDHeader] = requestID
        }
        let data: Data = try message.serializedData()
        return Response(status: status, headers: headers, body: .init(data: data))
    }
}

/// A standard error sent with a status other than its category's.
private struct StatusError: ProtobufErrorConvertible {
    let status: HTTPResponse.Status
    let headers: HTTPFields
    let error: StandardError

    var body: any SwiftProtobuf.Message { error.detail }
    var responseHeaders: HTTPFields { headers }
    var logDescription: String { "\(status.code) \(error)" }
}

/// Something went wrong that the client has no business seeing the details of.
private struct UnexpectedError: ProtobufErrorConvertible {
    let error = StandardError(.internal, "internal error")

    var status: HTTPResponse.Status { error.status }
    var body: any SwiftProtobuf.Message { error.detail }
    var logDescription: String { "unexpected error" }
}

extension SwiftProtobuf.Message {
    /// This message as an HTTP response.
    public func response(
        status: HTTPResponse.Status = .ok,
        requestID: String? = nil,
        configuration: ProtobufWireConfiguration = .current
    ) throws -> Response {
        try ProtobufResponse.success(
            self, status: status, requestID: requestID, configuration: configuration
        )
    }
}

/// Wraps a message so a route can return it directly, with a status and
/// headers if it needs them.
///
/// ```swift
/// @POST("v1", "notes")
/// func create(req: Request) async throws -> Protobuf<Notes_Note> {
///     let request = try await req.protobuf(Notes_CreateNoteRequest.self)
///     return Protobuf(try await store.create(request), status: .created)
/// }
/// ```
///
/// Messages that conform to ``ProtobufResponseEncodable`` can be returned
/// without the wrapper.
public struct Protobuf<M: SwiftProtobuf.Message & Sendable>: ResponseEncodable {
    public var message: M
    public var status: HTTPResponse.Status
    public var headers: HTTPFields

    /// `nil`: the request's (``ProtobufWireConfiguration/current``).
    public var configuration: ProtobufWireConfiguration?

    public init(
        _ message: M, status: HTTPResponse.Status = .ok, headers: HTTPFields = [:],
        configuration: ProtobufWireConfiguration? = nil
    ) {
        self.message = message
        self.status = status
        self.headers = headers
        self.configuration = configuration
    }

    public func encodeResponse(for request: Request) async throws -> Response {
        let configuration = configuration ?? .current
        return try ProtobufResponse.success(
            message, status: status, headers: headers,
            requestID: request.requestID(configuration), configuration: configuration
        )
    }
}

/// A message a route can return as it is: `200`, protobuf body.
///
/// Swift cannot make every generated message `ResponseEncodable` at once, so
/// conform the ones your routes return, one line each:
///
/// ```swift
/// extension Notes_Note: ProtobufResponseEncodable {}
///
/// @GET("v1", "notes", UUID.self)
/// func get(req: Request, id: UUID) async throws -> Notes_Note { … }
/// ```
public protocol ProtobufResponseEncodable: SwiftProtobuf.Message, ResponseEncodable {}

extension ProtobufResponseEncodable {
    public func encodeResponse(for request: Request) async throws -> Response {
        let configuration = ProtobufWireConfiguration.current
        return try ProtobufResponse.success(
            self, requestID: request.requestID(configuration), configuration: configuration
        )
    }
}
