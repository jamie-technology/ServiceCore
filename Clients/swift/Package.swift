// swift-tools-version: 6.2
import PackageDescription

// The client side of ServiceCore's AuthenticationCore, for apps and their
// extensions: keeps the newest access token across processes, and retries
// requests whose token another request has just refreshed.
//
// A package of its own, so apps don't resolve the server's dependencies
// (Vapor, FoundationDB).
let package = Package(
    name: "ServiceCoreClient",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10), .tvOS(.v17), .visionOS(.v1)],
    products: [
        .library(name: "AuthenticationClient", targets: ["AuthenticationClient"]),
    ],
    targets: [
        .target(
            name: "AuthenticationClient",
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "AuthenticationClientTests",
            dependencies: ["AuthenticationClient"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
    ]
)
