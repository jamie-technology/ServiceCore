// swift-tools-version: 6.4
import PackageDescription

// Shared plumbing for the Vapor + FoundationDB services.
//
// Issura, Aegis, Accounts, Automatio, CaledonianSleeper, DauntlessMail and
// Ideatum each grew their own copy of the same four things. They are here so
// the copies stop drifting apart:
//
// - FoundationDBCore: connecting to a cluster and opening a service's tenant.
// - RecordStore:      the FDB Record Layer on top of that (per-transaction
//                     store access, pagination, record versions).
// - BlobStore:        content-addressed blob storage, filesystem or S3.
// - ProtobufWireCore: protobuf-over-HTTP for Vapor, with structured,
//                     extensible error codes.
// - AuthenticationCore: signing in through accounts (OAuth) and authenticating
//                     requests, refreshing expired tokens. Storage-agnostic;
//                     AuthenticationFoundationDB stores sessions in FoundationDB.
//
// What is NOT here: anything domain-specific. A service's schema, wire
// messages and error codes stay in that service.
let package = Package(
    name: "ServiceCore",
    platforms: [
        .macOS("26.2")
    ],
    products: [
        .library(name: "FoundationDBCore", targets: ["FoundationDBCore"]),
        .library(name: "RecordStore", targets: ["RecordStore"]),
        .library(name: "BlobStore", targets: ["BlobStore"]),
        .library(name: "ProtobufWireCore", targets: ["ProtobufWireCore"]),
        .library(name: "AuthenticationCore", targets: ["AuthenticationCore"]),
        .library(name: "AuthenticationFoundationDB", targets: ["AuthenticationFoundationDB"]),
        .executable(name: "service-init", targets: ["service-init"]),
    ],
    dependencies: [
        // 💧 A server-side Swift web framework.
        .package(url: "https://github.com/vapor/vapor.git", from: "5.0.0-beta.4"),
        // ⚙️ Configuration readers; Vapor depends on these, but we import them directly.
        .package(url: "https://github.com/apple/swift-configuration.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        // FoundationDB swift bindings, with the Record Layer.
        .package(
            url: "https://github.com/itspolly/fdb-swift-bindings.git",
            branch: "main",
            traits: ["RecordLayer"]
        ),
        .package(url: "https://github.com/apple/swift-protobuf.git", branch: "main"),
        // HTTPResponse.Status and friends; Vapor uses these but does not re-export them.
        .package(url: "https://github.com/apple/swift-http-types", from: "1.7.0"),
        // SHA-256 and HMAC for content addressing and SigV4.
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0" ..< "6.0.0"),
        // Command-line parsing for service-init.
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // Connecting to FoundationDB and opening a tenant. No HTTP, no Record Layer.
        .target(
            name: "FoundationDBCore",
            dependencies: [
                .product(name: "FoundationDB", package: "fdb-swift-bindings"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings,
            linkerSettings: fdbLinkerSettings
        ),
        // The Record Layer on top of a FoundationDBCore connection. No HTTP.
        .target(
            name: "RecordStore",
            dependencies: [
                "FoundationDBCore",
                .product(name: "FoundationDB", package: "fdb-swift-bindings"),
                .product(name: "FDBRecordLayer", package: "fdb-swift-bindings"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: swiftSettings,
            linkerSettings: fdbLinkerSettings
        ),
        // Content-addressed blobs on a filesystem or an S3-compatible bucket.
        // Depends on Vapor only for its HTTP client, which the S3 backend uses.
        .target(
            name: "BlobStore",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: swiftSettings
        ),
        // Protobuf over HTTP for Vapor: decoding requests, encoding success and
        // failure responses, and the shared `ErrorDetail` / `ErrorCode` wire types.
        .target(
            name: "ProtobufWireCore",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings,
            plugins: [
                .plugin(name: "SwiftProtobufPlugin", package: "swift-protobuf")
            ]
        ),
        // OAuth against accounts: sign-in, an authentication middleware, and
        // token refresh. Sessions live behind the `SessionStore` protocol.
        .target(
            name: "AuthenticationCore",
            dependencies: [
                "ProtobufWireCore",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: swiftSettings
        ),
        // AuthenticationCore's sessions in a FoundationDB tenant, on the Record Layer.
        .target(
            name: "AuthenticationFoundationDB",
            dependencies: [
                "AuthenticationCore",
                "FoundationDBCore",
                "RecordStore",
                .product(name: "FoundationDB", package: "fdb-swift-bindings"),
                .product(name: "FDBRecordLayer", package: "fdb-swift-bindings"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: swiftSettings,
            linkerSettings: fdbLinkerSettings,
            plugins: [
                .plugin(name: "SwiftProtobufPlugin", package: "swift-protobuf")
            ]
        ),
        // Scaffolds a new Vapor 5 service on these libraries.
        .executableTarget(
            name: "service-init",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: swiftSettings
        ),

        .testTarget(
            name: "FoundationDBCoreTests",
            dependencies: [
                "FoundationDBCore",
                .product(name: "FoundationDB", package: "fdb-swift-bindings"),
                .product(name: "Configuration", package: "swift-configuration"),
            ],
            swiftSettings: swiftSettings,
            linkerSettings: fdbLinkerSettings
        ),
        .testTarget(
            name: "RecordStoreTests",
            dependencies: [
                "RecordStore",
                "FoundationDBCore",
                .product(name: "FoundationDB", package: "fdb-swift-bindings"),
                .product(name: "FDBRecordLayer", package: "fdb-swift-bindings"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: swiftSettings,
            linkerSettings: fdbLinkerSettings
        ),
        .testTarget(
            name: "BlobStoreTests",
            dependencies: [
                "BlobStore",
                .product(name: "Configuration", package: "swift-configuration"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ProtobufWireCoreTests",
            dependencies: [
                "ProtobufWireCore",
                .product(name: "VaporTesting", package: "vapor"),
                .product(name: "VaporMacros", package: "vapor"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AuthenticationCoreTests",
            dependencies: [
                "AuthenticationCore",
                "AuthenticationFoundationDB",
                "FoundationDBCore",
                "RecordStore",
                "ProtobufWireCore",
                .product(name: "FDBRecordLayer", package: "fdb-swift-bindings"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "VaporTesting", package: "vapor"),
                .product(name: "VaporMacros", package: "vapor"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: swiftSettings,
            linkerSettings: fdbLinkerSettings
        ),
    ]
)

var swiftSettings: [SwiftSetting] {
    [
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    ]
}

// macOS: libfdb_c.dylib ships with the FoundationDB client install at
// /usr/local/lib with install name @rpath/libfdb_c.dylib, so search that dir at
// link time (the client install ships no pkg-config file) and embed it as an
// rpath for dyld. On Linux the client is libfdb_c.so under /usr/lib, which is
// already on the default loader search path.
var fdbLinkerSettings: [LinkerSetting] {
    [
        .unsafeFlags(
            ["-L/usr/local/lib", "-Xlinker", "-rpath", "-Xlinker", "/usr/local/lib"],
            .when(platforms: [.macOS])
        )
    ]
}
