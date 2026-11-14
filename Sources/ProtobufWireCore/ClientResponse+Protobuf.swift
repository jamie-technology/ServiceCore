import Foundation
public import HTTPTypes
public import SwiftProtobuf
public import Vapor

/// A call to another service failed.
public struct RemoteServiceError: Error, Sendable, CustomStringConvertible {
    public let status: HTTPResponse.Status

    /// The error the service sent, or `nil` if its body was not an
    /// `ErrorDetail` (a proxy's error page, say).
    public let detail: WireErrorDetail?

    public init(status: HTTPResponse.Status, detail: WireErrorDetail?) {
        self.status = status
        self.detail = detail
    }

    /// The standard category, from the body if there was one, else the status.
    public var category: WireErrorCode {
        detail?.code ?? WireErrorCode(status: status)
    }

    public var isRetryable: Bool {
        detail?.retryable ?? category.isRetryable
    }

    /// The service-specific code, if the error is from `C`'s domain.
    public func code<C: ServiceErrorCode>(as type: C.Type) -> C? {
        detail?.code(as: type)
    }

    public var description: String {
        guard let detail else { return "remote service answered \(status.code)" }
        return "remote service answered \(status.code): \(detail.message) [\(detail.code)]"
    }
}

extension ClientResponse {
    /// Decodes a protobuf response from another service.
    ///
    /// - Throws: ``RemoteServiceError`` for a non-2xx status, with the
    ///   service's `ErrorDetail` if it sent one.
    public func protobuf<M: SwiftProtobuf.Message>(
        _ type: M.Type = M.self, max: BodySizeLimit = .default
    ) async throws -> M {
        let data = try await body.data(max: max) ?? Data()
        guard (200..<300).contains(status.code) else {
            throw RemoteServiceError(
                status: status, detail: try? WireErrorDetail(serializedBytes: data)
            )
        }
        return try M(serializedBytes: data)
    }
}

extension ClientRequest {
    /// Sets the body to `message`, with the protobuf content type.
    public mutating func setProtobuf(
        _ message: some SwiftProtobuf.Message, configuration: ProtobufWireConfiguration = .current
    ) throws {
        let data: Data = try message.serializedData()
        headers[.contentType] = configuration.contentType
        body = .init(data: data)
    }
}
