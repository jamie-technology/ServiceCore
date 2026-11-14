import Foundation
import os

/// Answers requests to `https://<host>/…` with a handler, per host, so tests
/// can run in parallel.
final class StubServer: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (status: Int, headers: [String: String])

    private static let handlers = OSAllocatedUnfairLock<[String: Handler]>(initialState: [:])

    /// A session whose requests to the returned host go to `handler`.
    static func session(_ handler: @escaping Handler) -> (URLSession, host: String) {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        handlers.withLock { $0[host] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        configuration.timeoutIntervalForRequest = 5
        return (URLSession(configuration: configuration), host)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        guard let host = request.url?.host, let handler = Self.handlers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        Task {
            do {
                let (status, headers) = try await handler(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data())
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}

extension URLRequest {
    /// The body as the server sees it: URLSession hands protocols a stream.
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    var bearer: String? {
        value(forHTTPHeaderField: "Authorization").map { String($0.dropFirst("Bearer ".count)) }
    }
}

let invalidToken = ["X-Authentication-Error": "invalid_access_token"]
