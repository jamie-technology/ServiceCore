public import Configuration
import Foundation
public import Vapor
import Logging

/// Which blob backend a deployment uses.
public enum BlobBackend: Sendable, Hashable {
    case filesystem(root: String)
    case s3(S3BlobStore.Configuration)

    /// Reads the backend from `config` under `scope` (by default
    /// `storage.blobs`, so `STORAGE_BLOBS_*` in the environment):
    ///
    /// - `backend`: `filesystem` (default) or `s3`.
    /// - `root`: the directory for the filesystem backend; defaults to
    ///   `defaultRoot`.
    /// - `s3.endpoint`, `s3.bucket`, `s3.access.key.id`, `s3.secret.access.key`:
    ///   required for the S3 backend.
    /// - `s3.region`, `s3.session.token`, `s3.path.style`, `s3.prefix`: optional.
    public init(config: ConfigReader, scope: String = "storage.blobs", defaultRoot: String = "blobs") throws {
        let blobs = config.scoped(to: ConfigKey(scope))
        switch blobs.string(forKey: "backend", default: "filesystem") {
        case "filesystem":
            self = .filesystem(root: blobs.string(forKey: "root", default: defaultRoot))

        case "s3":
            let s3 = blobs.scoped(to: "s3")
            let endpoint = try s3.requiredString(forKey: "endpoint")
            guard let endpointURL = URL(string: endpoint), endpointURL.host() != nil else {
                throw BlobConfigurationError.invalidEndpoint(endpoint)
            }
            self = .s3(
                S3BlobStore.Configuration(
                    endpoint: endpointURL,
                    bucket: try s3.requiredString(forKey: "bucket"),
                    region: s3.string(forKey: "region", default: "us-east-1"),
                    accessKeyID: try s3.requiredString(forKey: "access.key.id"),
                    secretAccessKey: try s3.requiredString(forKey: "secret.access.key", isSecret: true),
                    sessionToken: s3.string(forKey: "session.token", isSecret: true),
                    usePathStyle: s3.bool(forKey: "path.style", default: true),
                    prefix: s3.string(forKey: "prefix", default: "")
                )
            )

        case let other:
            throw BlobConfigurationError.unknownBackend(other)
        }
    }

    /// Builds the store this backend describes.
    ///
    /// - Parameter client: The HTTP client the S3 backend sends requests
    ///   through; unused by the filesystem backend.
    public func makeStore(client: any Client) throws -> any BlobStore {
        switch self {
        case .filesystem(let root):
            let url = URL(fileURLWithPath: root)
            Logger.current.info(
                "blob storage: filesystem",
                metadata: ["root": .string(url.path(percentEncoded: false))]
            )
            return try FilesystemBlobStore(root: url)

        case .s3(let configuration):
            Logger.current.info(
                "blob storage: S3",
                metadata: [
                    "endpoint": .string(configuration.endpoint.absoluteString),
                    "bucket": .string(configuration.bucket),
                ]
            )
            return S3BlobStore(configuration: configuration, client: client)
        }
    }
}

public enum BlobConfigurationError: Error, Equatable, CustomStringConvertible {
    case unknownBackend(String)
    case invalidEndpoint(String)

    public var description: String {
        switch self {
        case .unknownBackend(let name):
            "unknown blob backend '\(name)'; expected 'filesystem' or 's3'"
        case .invalidEndpoint(let endpoint):
            "S3 endpoint '\(endpoint)' is not a valid URL"
        }
    }
}
