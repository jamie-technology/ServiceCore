public import HTTPTypes
public import Logging
public import RoutingKit
public import SwiftProtobuf
public import Vapor

extension RoutesBuilder {
    /// Registers a protobuf RPC: decodes the body as `Input`, runs `handler`,
    /// and answers with its `Output`, or with the error it threw as an
    /// `ErrorDetail` (see ``ProtobufResponse/failure(_:requestID:configuration:logger:)``).
    ///
    /// ```swift
    /// app.protobuf("v1", "zones", "lookup") { (request: LookupZonesRequest, _) in
    ///     try await store.lookupZones(request)
    /// }
    /// ```
    ///
    /// Errors are handled here rather than left to middleware, so a route works
    /// the same whatever middleware the application has.
    ///
    /// Prefer a `@Controller` with VaporMacros for new code (see the README);
    /// this suits a route or two defined inline.
    ///
    /// - Parameter configuration: `nil` uses the request's
    ///   (``ProtobufWireConfiguration/current``), as set by `useProtobufErrors`.
    @discardableResult
    public func protobuf<Input: SwiftProtobuf.Message, Output: SwiftProtobuf.Message>(
        _ path: [PathComponent],
        method: HTTPRequest.Method = .post,
        maxBodySize: ByteCount? = nil,
        configuration: ProtobufWireConfiguration? = nil,
        use handler: @Sendable @escaping (Input, Request) async throws -> Output
    ) -> Route {
        on(method, path, maxBodySize: maxBodySize) { request -> Response in
            let configuration = configuration ?? .current
            let requestID = request.requestID(configuration)
            return await ProtobufWireConfiguration.$current.withValue(configuration) {
                do {
                    let input = try await request.protobuf(Input.self)
                    let output = try await handler(input, request)
                    return try ProtobufResponse.success(
                        output, requestID: requestID, configuration: configuration
                    )
                } catch {
                    return ProtobufResponse.failure(
                        error, requestID: requestID, configuration: configuration
                    )
                }
            }
        }
    }

    @discardableResult
    public func protobuf<Input: SwiftProtobuf.Message, Output: SwiftProtobuf.Message>(
        _ path: PathComponent...,
        method: HTTPRequest.Method = .post,
        maxBodySize: ByteCount? = nil,
        configuration: ProtobufWireConfiguration? = nil,
        use handler: @Sendable @escaping (Input, Request) async throws -> Output
    ) -> Route {
        protobuf(path, method: method, maxBodySize: maxBodySize, configuration: configuration, use: handler)
    }

    /// Registers a route whose response is not protobuf (a download, a
    /// redirect) but whose failures should still be `ErrorDetail` bodies.
    @discardableResult
    public func protobufErrors(
        _ method: HTTPRequest.Method,
        _ path: PathComponent...,
        maxBodySize: ByteCount? = nil,
        configuration: ProtobufWireConfiguration? = nil,
        use handler: @Sendable @escaping (Request) async throws -> Response
    ) -> Route {
        on(method, path, maxBodySize: maxBodySize) { request -> Response in
            let configuration = configuration ?? .current
            return await ProtobufWireConfiguration.$current.withValue(configuration) {
                do {
                    return try await handler(request)
                } catch {
                    return ProtobufResponse.failure(
                        error, requestID: request.requestID(configuration), configuration: configuration
                    )
                }
            }
        }
    }
}

/// Turns anything thrown below it into an `ErrorDetail` body, and makes
/// ``configuration`` the ``ProtobufWireConfiguration/current`` one for
/// everything below it.
///
/// Vapor's default `ErrorMiddleware` converts a thrown error into a JSON body
/// rather than rethrowing, so ordering alone cannot get in front of it: it has
/// to be replaced. Use ``Vapor/Application/useProtobufErrors(configuration:logLevel:)``.
public struct ProtobufErrorMiddleware: Middleware {
    public let configuration: ProtobufWireConfiguration

    public init(configuration: ProtobufWireConfiguration = .default) {
        self.configuration = configuration
    }

    public func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        let configuration = configuration
        return await ProtobufWireConfiguration.$current.withValue(configuration) {
            do {
                return try await next.respond(to: request)
            } catch {
                return ProtobufResponse.failure(
                    error, requestID: request.requestID(configuration), configuration: configuration
                )
            }
        }
    }
}

extension Application {
    /// Replaces Vapor's JSON error middleware with ``ProtobufErrorMiddleware``,
    /// keeping route logging in front of it.
    public func useProtobufErrors(
        configuration: ProtobufWireConfiguration = .default,
        logLevel: Logger.Level = .info
    ) {
        var middleware = Middlewares()
        middleware.use(RouteLoggingMiddleware(logLevel: logLevel))
        middleware.use(ProtobufErrorMiddleware(configuration: configuration))
        self.middleware = middleware
    }
}
