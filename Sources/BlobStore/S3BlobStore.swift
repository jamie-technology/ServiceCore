public import Foundation
public import Vapor
import HTTPTypes
import NIOCore

/// Any S3-compatible object store: AWS, MinIO, R2, Garage.
///
/// Talks the S3 REST API directly with a self-contained SigV4 signer rather
/// than depending on an SDK; see ``SignatureV4`` for that trade.
public struct S3BlobStore: BlobStore {
    public struct Configuration: Sendable, Hashable {
        public var endpoint: URL
        public var bucket: String
        public var region: String
        public var accessKeyID: String
        public var secretAccessKey: String
        public var sessionToken: String?
        /// Path-style (`endpoint/bucket/key`) rather than virtual-host
        /// (`bucket.endpoint/key`). MinIO and most self-hosted stores need this,
        /// and it is the safer default for an unfamiliar endpoint.
        public var usePathStyle: Bool
        /// Optional key prefix, so one bucket can hold several deployments.
        public var prefix: String

        public init(
            endpoint: URL,
            bucket: String,
            region: String = "us-east-1",
            accessKeyID: String,
            secretAccessKey: String,
            sessionToken: String? = nil,
            usePathStyle: Bool = true,
            prefix: String = ""
        ) {
            self.endpoint = endpoint
            self.bucket = bucket
            self.region = region
            self.accessKeyID = accessKeyID
            self.secretAccessKey = secretAccessKey
            self.sessionToken = sessionToken
            self.usePathStyle = usePathStyle
            self.prefix = prefix
        }
    }

    private let configuration: Configuration
    private let client: any Client

    public init(configuration: Configuration, client: any Client) {
        self.configuration = configuration
        self.client = client
    }

    private var signer: SignatureV4 {
        SignatureV4(
            accessKeyID: configuration.accessKeyID,
            secretAccessKey: configuration.secretAccessKey,
            sessionToken: configuration.sessionToken,
            region: configuration.region,
            service: "s3"
        )
    }

    /// The object URL for `key`.
    public func url(for key: BlobKey) -> URL {
        var path = key.shardedPath
        let prefix = configuration.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !prefix.isEmpty {
            path = "\(prefix)/\(path)"
        }
        if configuration.usePathStyle {
            return configuration.endpoint.appending(path: "\(configuration.bucket)/\(path)")
        }
        // Virtual-host style: the bucket is part of the host, so the URL the
        // request goes to has to carry it too, not just the signed header.
        var components = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false)
        if let host = components?.host {
            components?.host = "\(configuration.bucket).\(host)"
        }
        let base = components?.url ?? configuration.endpoint
        return base.appending(path: path)
    }

    private func host(for url: URL) -> String {
        guard let host = url.host() else { return "" }
        // The signed host must match the Host header exactly, and a non-default
        // port is part of it.
        if let port = url.port, !Self.isDefaultPort(port, scheme: url.scheme) {
            return "\(host):\(port)"
        }
        return host
    }

    private static func isDefaultPort(_ port: Int, scheme: String?) -> Bool {
        (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
    }

    private func send(
        method: HTTPRequest.Method, key: BlobKey, body: Data
    ) async throws -> ClientResponse {
        let url = url(for: key)
        let signed = signer.sign(
            method: method.rawValue,
            url: url,
            headers: ["host": host(for: url)],
            payload: body
        )

        var headers = HTTPFields()
        for (name, value) in signed {
            guard let field = HTTPField.Name(name) else { continue }
            headers[field] = value
        }

        var request = ClientRequest(method: method, url: URI(string: url.absoluteString))
        request.headers = headers
        if !body.isEmpty {
            request.body = .init(data: body)
        }

        do {
            return try await client.send(request)
        } catch {
            throw BlobStoreError.backend("\(error)")
        }
    }

    public func put(_ key: BlobKey, bytes: Data) async throws {
        let response = try await send(method: .put, key: key, body: bytes)
        guard (200..<300).contains(Int(response.status.code)) else {
            throw BlobStoreError.backend(
                "PUT returned \(response.status.code): \(await Self.errorText(response))"
            )
        }
    }

    public func get(_ key: BlobKey) async throws -> Data? {
        let response = try await send(method: .get, key: key, body: Data())
        if response.status == .notFound { return nil }
        guard (200..<300).contains(Int(response.status.code)) else {
            throw BlobStoreError.backend(
                "GET returned \(response.status.code): \(await Self.errorText(response))"
            )
        }
        // Unlimited because the blob is held in memory whole either way; the
        // size cap belongs on the way in, not on reading back what was stored.
        return try await response.body.data(max: .unlimited) ?? Data()
    }

    public func exists(_ key: BlobKey) async throws -> Bool {
        let response = try await send(method: .head, key: key, body: Data())
        if response.status == .notFound { return false }
        guard (200..<300).contains(Int(response.status.code)) else {
            throw BlobStoreError.backend("HEAD returned \(response.status.code)")
        }
        return true
    }

    public func delete(_ key: BlobKey) async throws {
        let response = try await send(method: .delete, key: key, body: Data())
        // S3 answers 204 for a delete whether or not the object was there, and a
        // 404 from some implementations means the same thing. Missing is not an
        // error: GC races with itself and with concurrent writers.
        guard (200..<300).contains(Int(response.status.code))
            || response.status == .notFound else {
            throw BlobStoreError.backend(
                "DELETE returned \(response.status.code): \(await Self.errorText(response))"
            )
        }
    }

    private static func errorText(_ response: ClientResponse) async -> String {
        guard let text = try? await response.body.string(max: .unlimited) else { return "" }
        return text
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(300)
            .description
    }
}
