import Foundation
import HTTPTypes
public import SwiftProtobuf
public import Vapor

extension Request {
    /// Decodes the request body as `M`.
    ///
    /// An empty body decodes to a default message: a request with no fields
    /// set is legitimate, and is exactly what a correct client sends for one.
    /// A body that is not a valid `M` throws ``StandardError`` with
    /// `invalidArgument`. The route's maximum body size applies.
    public func protobuf<M: SwiftProtobuf.Message>(
        _ type: M.Type = M.self,
        max: BodySizeLimit = .default,
        options: BinaryDecodingOptions = BinaryDecodingOptions()
    ) async throws -> M {
        guard let data = try await body.data(max: max), !data.isEmpty else { return M() }
        do {
            return try M(serializedBytes: data, options: options)
        } catch {
            throw StandardError.invalidArgument("could not decode \(M.protoMessageName) from the request body")
        }
    }

    /// The bearer token from `Authorization`, if there is one.
    public var bearerToken: String? {
        headers.bearerAuthorization?.token
    }

    /// The request ID the client sent, or a fresh one.
    ///
    /// A fresh one is not remembered, so read this once per request and pass
    /// the value along.
    public func requestID(_ configuration: ProtobufWireConfiguration = .current) -> String {
        if let sent = headers[configuration.requestIDHeader], !sent.isEmpty, sent.count <= 128 {
            return sent
        }
        return UUID().uuidString.lowercased()
    }
}
