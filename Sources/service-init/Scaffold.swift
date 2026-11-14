/// Renders a new service's files.
///
/// The baseline is `vapor new <name> --branch vapor5` reproduced file for
/// file; each option adds to it. Templates are raw strings (`#"""`), so
/// `\(…)` is Swift in the generated file and `\#(…)` is filled in here.
struct Scaffold {
    let options: ScaffoldOptions

    init(_ options: ScaffoldOptions) {
        self.options = options
    }

    private var name: String { options.name.typeName }

    /// Every file to write, by path relative to the service's root.
    func files() -> [String: String] {
        var files: [String: String] = [
            "Package.swift": packageManifest(),
            "README.md": readme(),
            "Dockerfile": options.usesFDB ? fdbDockerfile() : dockerfile(),
            "docker-compose.yml": dockerCompose(),
            ".gitignore": gitignore(),
            ".dockerignore": ".build/\n.swiftpm/\n",
            ".devcontainer/devcontainer.json": devcontainer(),
            ".vscode/extensions.json": #"""
                {
                    "recommendations": ["swiftlang.swift-vscode", "Vapor.vapor-vscode"]
                }

                """#,
            "Public/.gitkeep": "",
            "Sources/\(name)/Controllers/.gitkeep": "",
            "Sources/\(name)/entrypoint.swift": entrypoint(),
            "Sources/\(name)/configure.swift": configure(),
            "Sources/\(name)/routes.swift": routes(),
            "Tests/\(name)Tests/AppTrait.swift": appTrait(),
            "Tests/\(name)Tests/\(name)Tests.swift": tests(),
        ]
        if options.hasServices {
            files["Sources/\(name)/Services.swift"] = services()
        }
        if options.usesRecords {
            files["Sources/\(name)/swift-protobuf-config.json"] = protobufConfig(
                files: ["Models/Database/Greeting.proto"], visibility: "internal"
            )
            files["Sources/\(name)/Models/Database/Greeting.proto"] = greetingProto()
            files["Sources/\(name)/Models/Database/Schema.swift"] = schema()
        }
        if options.wireLibrary {
            files["Sources/WireModels/swift-protobuf-config.json"] = protobufConfig(
                files: options.authentication ? ["Hello.proto", "Authentication.proto"] : ["Hello.proto"],
                visibility: "public"
            )
            files["Sources/WireModels/Hello.proto"] = helloProto()
            files["Sources/WireModels/WireModels.swift"] = wireModelsSwift()
            files["Sources/\(name)/Controllers/HelloController.swift"] = helloController()
        }
        if options.authentication {
            files["Sources/WireModels/Authentication.proto"] = authenticationProto()
            files["Sources/\(name)/Controllers/AuthenticationController.swift"] = authenticationController()
            files["Tests/\(name)Tests/FakeAccounts.swift"] = fakeAccounts()
            files["Tests/\(name)Tests/AuthenticationTests.swift"] = authenticationTests()
        }
        return files
    }

    // MARK: - Package.swift

    private func packageManifest() -> String {
        var dependencies = [
            """
                    // 💧 A server-side Swift web framework.
                    .package(url: "https://github.com/vapor/vapor.git", from: "5.0.0-beta.4"),
            """,
            """
                    // 📝 Customizable logging to the console.
                    .package(url: "https://github.com/vapor/console-kit.git", from: "5.0.0-beta"),
            """,
            """
                    // ⚙️ Configuration readers; Vapor depends on these, but we import them directly.
                    .package(
                        url: "https://github.com/apple/swift-configuration.git",
                        from: "1.0.0",
                        traits: ["CommandLineArguments"]
                    ),
            """,
        ]
        if options.usesServiceCore {
            dependencies.append("""
                        // Shared service plumbing: \(options.serviceCoreProducts.joined(separator: ", ")).
                        \(options.serviceCore.packageDeclaration),
                """)
        }
        if options.usesFDB {
            dependencies.append("""
                        // FoundationDB swift bindings.
                        .package(
                            url: "git@github.com:itspolly/fdb-swift-bindings.git",
                            branch: "main"\(options.usesRecordLayer ? ",\n            traits: [\"RecordLayer\"]" : "")
                        ),
                """)
        }
        if options.usesProtobuf {
            dependencies.append("""
                        .package(url: "https://github.com/apple/swift-protobuf.git", branch: "main"),
                """)
        }

        var appDependencies = [
            #".product(name: "Vapor", package: "vapor")"#,
            #".product(name: "ConsoleLogger", package: "console-kit")"#,
            #".product(name: "Configuration", package: "swift-configuration")"#,
        ]
        appDependencies += options.serviceCoreProducts.map { #".product(name: "\#($0)", package: "ServiceCore")"# }
        if options.usesFDB {
            appDependencies.append(#".product(name: "FoundationDB", package: "fdb-swift-bindings")"#)
        }
        if options.usesRecords {
            appDependencies.append(#".product(name: "FDBRecordLayer", package: "fdb-swift-bindings")"#)
        }
        if options.usesProtobuf {
            appDependencies.append(#".product(name: "SwiftProtobuf", package: "swift-protobuf")"#)
        }
        if options.wireLibrary {
            appDependencies.append(#".product(name: "VaporMacros", package: "vapor")"#)
            appDependencies.append(#".target(name: "WireModels")"#)
        }

        var appTargetArguments = ["            swiftSettings: swiftSettings"]
        if options.usesFDB {
            appTargetArguments.append("            linkerSettings: fdbLinkerSettings")
        }
        if options.usesRecords {
            appTargetArguments.append("""
                            plugins: [
                                .plugin(name: "SwiftProtobufPlugin", package: "swift-protobuf")
                            ]
                """)
        }

        var targets: [String] = []
        if options.wireLibrary {
            targets.append(#"""
                        // The wire contract: request and response messages, shared with clients.
                        .target(
                            name: "WireModels",
                            dependencies: [
                                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                            ],
                            swiftSettings: swiftSettings,
                            plugins: [
                                .plugin(name: "SwiftProtobufPlugin", package: "swift-protobuf")
                            ]
                        ),
                """#)
        }
        targets.append("""
                    .executableTarget(
                        name: "\(name)",
                        dependencies: [
            \(appDependencies.map { "                \($0)," }.joined(separator: "\n"))
                        ],
            \(appTargetArguments.joined(separator: ",\n"))
                    ),
            """)

        var testDependencies = [
            #".target(name: "\#(name)")"#,
            #".product(name: "VaporTesting", package: "vapor")"#,
        ]
        if options.wireLibrary {
            testDependencies.append(#".target(name: "WireModels")"#)
            testDependencies.append(#".product(name: "ProtobufWireCore", package: "ServiceCore")"#)
        }
        if options.authentication {
            testDependencies.append(#".product(name: "AuthenticationCore", package: "ServiceCore")"#)
            testDependencies.append(#".product(name: "Configuration", package: "swift-configuration")"#)
        }
        targets.append("""
                    .testTarget(
                        name: "\(name)Tests",
                        dependencies: [
            \(testDependencies.map { "                \($0)," }.joined(separator: "\n"))
                        ],
                        swiftSettings: swiftSettings\(options.usesFDB ? ",\n            linkerSettings: fdbLinkerSettings" : "")
                    ),
            """)

        let products = options.wireLibrary
            ? """

                    products: [
                        .executable(name: "\(name)", targets: ["\(name)"]),
                        .library(name: "WireModels", targets: ["WireModels"]),
                    ],
                """
            : ""

        let linkerSettings = options.usesFDB
            ? #"""


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
                """#
            : ""

        return """
            // swift-tools-version:6.4
            import PackageDescription

            let package = Package(
                name: "\(name)",
                platforms: [
                    .macOS("26.2")
                ],\(products)
                dependencies: [
            \(dependencies.joined(separator: "\n"))
                ],
                targets: [
            \(targets.joined(separator: "\n"))
                ]
            )

            var swiftSettings: [SwiftSetting] {
                [
                    .enableUpcomingFeature("ExistentialAny"),
                    .enableUpcomingFeature("InternalImportsByDefault"),
                    .enableUpcomingFeature("MemberImportVisibility"),
                    .enableUpcomingFeature("InferIsolatedConformances"),
                    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                    .enableExperimentalFeature("SuppressedAssociatedTypesWithDefaults"),
                ]
            }\(linkerSettings)

            """
    }

    // MARK: - Sources

    private func entrypoint() -> String {
        #"""
        import Configuration
        import ConsoleLogger
        import Logging
        import Vapor

        @main
        enum Entrypoint {
            static func main() async throws {
                try await withLogger(.init(label: "vapor5.logger")) { _ in
                    let config = ConfigReader(providers: [
                        CommandLineArgumentsProvider(),
                        EnvironmentVariablesProvider(),
                    ])
                    ConsoleLogger.bootstrapWithConfigReader(config: config)

                    let app = try Application(configReader: config)
                    do {
                        try await configure(app)
                        try await app.run()
                        try await app.shutdown()
                    } catch {
                        try? await app.shutdown()
                        throw error
                    }
                }
            }
        }

        """#
    }

    private func configure() -> String {
        var imports = ["Vapor"]
        if options.wireLibrary { imports.append("ProtobufWireCore") }
        if options.authentication { imports.append("AuthenticationCore") }

        var body: [String] = [
            """
                // uncomment to serve files from /Public folder
                // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
            """
        ]
        if options.wireLibrary {
            body.append("""
                    // Errors from every route, not only the protobuf ones, go out as `ErrorDetail` bodies.
                    app.useProtobufErrors(configuration: .\(options.name.typeName.lowercasedFirst))
                """)
        }
        if options.hasServices {
            body.append("""
                    let services = try await makeServices(for: app\(options.authentication ? ", accountsClient: accountsClient" : ""))

                    // register routes
                    try await routes(app, services: services)
                """)
        } else {
            body.append("""
                    // register routes
                    try await routes(app)
                """)
        }

        var extensions = ""
        if options.wireLibrary {
            extensions = """


                extension ProtobufWireConfiguration {
                    /// How \(name) speaks protobuf: its request-ID header, and how errors it owns map onto wire errors.
                    static var \(name.lowercasedFirst): ProtobufWireConfiguration {
                        ProtobufWireConfiguration(requestIDHeader: HTTPField.Name("X-\(name)-Request-ID")!)
                    }
                }
                """
            imports.append("HTTPTypes")
        }

        return """
            \(imports.sorted().map { "import \($0)" }.joined(separator: "\n"))

            /// configures your application\(options.authentication ? "\n///\n/// - Parameter accountsClient: Talks to accounts in place of HTTP; tests pass a fake." : "")
            func configure(_ app: Application\(options.authentication ? ", accountsClient: (any AccountsOAuthClient)? = nil" : "")) async throws {
            \(body.joined(separator: "\n\n"))
            }\(extensions)

            """
    }

    private func services() -> String {
        var imports: Set<String> = ["Vapor"]
        var fields: [String] = []
        var setup: [String] = []
        var arguments: [String] = []

        if options.usesFDB {
            imports.insert("FoundationDBCore")
            setup.append("""
                    let database = try await FoundationDBConnection.connect(
                        defaultTenant: "\(options.name.kebabName)",
                        config: app.configReader
                    )
                """)
        }
        switch options.fdb {
        case .kv:
            fields.append("""
                    /// This service's FoundationDB tenant.
                    let database: FoundationDBConnection
                """)
            arguments.append("database: database")
        case .records:
            imports.insert("RecordStore")
            fields.append("""
                    /// This service's records, in its own FoundationDB tenant.
                    let records: RecordDatabase
                """)
            setup.append("""
                    let records = RecordDatabase(connection: database, metaData: schema, path: "records")
                """)
            arguments.append("records: records")
        case nil:
            break
        }
        if options.authentication {
            imports.insert("AuthenticationCore")
            fields.append("""
                    /// Where people sign in: accounts' URLs and this service's OAuth client.
                    let accounts: AccountsConfiguration

                    /// Signs people in through accounts and authenticates their requests.
                    let auth: AuthenticationService
                """)
            let store: String
            if options.usesFDB {
                imports.insert("AuthenticationFoundationDB")
                store = """
                    // Sessions (above all their refresh tokens) in this tenant, in a record store of their own.
                            store: FoundationDBSessionStore(connection: database)
                    """
            } else {
                store = """
                    // In memory: every restart signs everyone out. Use a persistent SessionStore in production.
                            store: InMemorySessionStore()
                    """
            }
            setup.append("""
                    let accounts = try AccountsConfiguration(config: app.configReader)
                    let auth = AuthenticationService(
                        accounts: accountsClient ?? HTTPAccountsOAuthClient(configuration: accounts, client: app.client),
                        \(store)
                    )
                """)
            arguments.append("accounts: accounts")
            arguments.append("auth: auth")
        }
        if options.blobStore {
            imports.insert("BlobStore")
            fields.append("""
                    /// Large, immutable content: a directory or an S3 bucket, chosen by `STORAGE_BLOBS_BACKEND`.
                    let blobs: any BlobStore
                """)
            setup.append("""
                    let blobs = try BlobBackend(config: app.configReader).makeStore(client: app.client)
                """)
            arguments.append("blobs: blobs")
        }

        return """
            \(imports.sorted().map { "import \($0)" }.joined(separator: "\n"))

            /// The shared state \(name)'s routes work against.
            ///
            /// Vapor 5 has no per-application storage and requests do not reach back to the application, so this is
            /// built once in `configure` and handed to the routes that need it.
            struct Services: Sendable {
            \(fields.joined(separator: "\n\n"))
            }

            /// Connects \(name) to its backing stores.
            func makeServices(for app: Application\(options.authentication ? ", accountsClient: (any AccountsOAuthClient)? = nil" : "")) async throws -> Services {
            \(setup.joined(separator: "\n"))
                return Services(\(arguments.joined(separator: ", ")))
            }

            """
    }

    private func routes() -> String {
        var imports: Set<String> = ["RoutingKit", "Vapor"]
        var sections: [String] = [
            """
                app.get { req async in
                    "It works!"
                }

                app.get("hello") { req async -> String in
                    "Hello, world!"
                }
            """
        ]

        if options.fdb == .kv {
            imports.insert("FoundationDB")
            imports.insert("FoundationDBCore")
            sections.append(#"""
                    // A counter in FoundationDB's key-value layer. The atomic add never conflicts, however many requests race.
                    app.post("visits") { _ async throws -> String in
                        let key = Array("visits".utf8)
                        let visits = try await services.database.withTransaction { transaction in
                            transaction.atomicOp(key: key, param: withUnsafeBytes(of: Int64(1).littleEndian, Array.init), mutationType: .add)
                            return try await transaction.getValue(for: key)
                        }
                        let count = visits.map { bytes in
                            bytes.reversed().reduce(Int64(0)) { $0 << 8 | Int64($1) }
                        } ?? 0
                        return "\(count) visits"
                    }
                """#)
        }

        if options.usesRecords && !options.wireLibrary {
            imports.insert("HTTPTypes")
            imports.insert("FDBRecordLayer")
            imports.insert("FoundationDB")
            sections.append(#"""
                    // Records: count how often each name has been greeted.
                    app.post("greetings", ":name") { req async throws -> String in
                        guard let name = req.parameters.get("name") else { throw Abort(.badRequest) }
                        let greeting = try await services.records.recordGreeting(for: name)
                        return "Hello, \(greeting.name)! (greeted \(greeting.count) times)"
                    }
                """#)
        }

        if options.wireLibrary {
            sections.append("""
                    // Protobuf RPCs, written as a VaporMacros controller: see Controllers/HelloController.swift.
                    try await app.register(collection: HelloController(\(options.usesRecords ? "records: services.records" : "")))
                """)
        }

        if options.blobStore {
            imports.insert("BlobStore")
            imports.insert("Foundation")
            imports.insert("HTTPTypes")
            sections.append(#"""
                    // Content-addressed blobs: upload returns the SHA-256 the content is stored under.
                    app.on(.post, "blobs", maxBodySize: "16mb") { req async throws -> String in
                        let bytes = try await req.body.data() ?? Data()
                        let digest = SHA256Digest.hex(of: bytes)
                        guard let key = BlobKey(scope: "public", hex: digest) else { throw Abort(.internalServerError) }
                        try await services.blobs.putVerified(key, bytes: bytes)
                        return digest
                    }

                    app.get("blobs", ":digest") { req async throws -> Response in
                        guard let digest = req.parameters.get("digest"),
                              let key = BlobKey(scope: "public", hex: digest) else {
                            throw Abort(.badRequest, reason: "not a SHA-256 digest")
                        }
                        guard let bytes = try await services.blobs.get(key) else { throw Abort(.notFound) }
                        var headers = HTTPFields()
                        headers[.contentType] = "application/octet-stream"
                        return Response(status: .ok, headers: headers, body: .init(data: bytes))
                    }
                """#)
        }

        if options.authentication {
            sections.append("""
                    // Sign-in, sign-out and an authenticated example route: see Controllers/AuthenticationController.swift.
                    try await app.register(collection: AuthenticationController(auth: services.auth, accounts: services.accounts))
                """)
        }

        let signature = options.hasServices
            ? "func routes(_ app: Application, services: Services) async throws {"
            : "func routes(_ app: Application) async throws {"

        var helpers = ""
        if options.usesRecords {
            let db = options.databasePrefix
            imports.insert("FDBRecordLayer")
            imports.insert("FoundationDB")
            imports.insert("RecordStore")
            imports.insert("SwiftProtobuf")
            helpers = #"""


                extension RecordDatabase {
                    /// Counts a greeting for `name`, in one transaction so concurrent greetings never lose a count.
                    func recordGreeting(for name: String) async throws -> \#(db)Greeting {
                        try await withStore { store in
                            var greeting = try await store.load(\#(db)Greeting.self, primaryKey: Tuple([name]))?.record
                                ?? \#(db)Greeting.with { $0.name = name }
                            greeting.count += 1
                            try await store.save(greeting)
                            return greeting
                        }
                    }
                }
                """#
        }

        return """
            \(imports.sorted().map { "import \($0)" }.joined(separator: "\n"))

            \(signature)
            \(sections.joined(separator: "\n\n"))
            }\(helpers)

            """
    }

    private func schema() -> String {
        let db = options.databasePrefix
        return #"""
            import FDBRecordLayer

            // \#(name)'s FoundationDB schema.
            //
            // House rule: every record type and every index carries an explicit, hand-assigned key. Positional assignment
            // would mean that reordering these declarations silently relocates every existing record — no error, no
            // warning, data simply gone.
            //
            // KEY REGISTRY — keys are permanent. Never reuse a retired one. Index keys are `recordTypeKey * 100 + n`.
            //
            // | Key | Record type | Indexes   |
            // |-----|-------------|-----------|
            // | 1   | Greeting    | 101 count |
            //
            // Retired keys: none yet.
            let schema = RecordMetaData(version: 1) {
                RecordType(\#(db)Greeting.self, key: 1, primaryKey: \.name)
                    .index("greeting.count", on: \.count, key: 101)
                    .storingVersions()
            }

            """#
    }

    private func greetingProto() -> String {
        """
        syntax = "proto3";

        // \(name)'s database records. Private to this service: never share these with clients.
        package \(options.databasePackage);

        message Greeting {
            string name = 1;
            int64 count = 2;
        }

        """
    }

    private func helloProto() -> String {
        """
        syntax = "proto3";

        // \(name)'s wire contract, shared with clients.
        //
        // Failures are `servicecore.wire.v1.ErrorDetail` bodies, from ProtobufWireCore.
        package \(options.wirePackage);

        message HelloRequest {
            string name = 1;
        }

        message HelloResponse {
            string message = 1;
            // How many times this name has been greeted.
            int64 count = 2;
        }

        """
    }

    /// SwiftPM counts only Swift sources when deciding whether a target is
    /// empty, and a target of nothing but `.proto` files would be.
    private func wireModelsSwift() -> String {
        """
        // \(name)'s wire contract. The messages are generated from the `.proto` files in this directory.

        /// The `Content-Type` of every \(name) request and response body.
        public let \(name.lowercasedFirst)ProtobufContentType = "application/x-protobuf"

        """
    }

    private func protobufConfig(files: [String], visibility: String) -> String {
        """
        {
          "invocations": [
            {
              "protoFiles": [
        \(files.map { "        \"\($0)\"" }.joined(separator: ",\n"))
              ],
              "visibility": "\(visibility)",
              "useAccessLevelOnImports": true
            }
          ]
        }

        """
    }

    // MARK: - Tests

    private func appTrait() -> String {
        #"""
        import Testing
        import Vapor
        import VaporTesting

        @testable import \#(name)

        @TaskLocal var _application: Application?

        struct AppTrait: TestTrait, SuiteTrait, TestScoping {
            var isRecursive: Bool { true }

            func provideScope(
                for test: Test, testCase: Test.Case?, performing function: @Sendable @concurrent () async throws -> Void
            ) async throws {
                try await VaporTesting::withApp(\#(options.authentication ? "configReader: testConfiguration, configure: { try await configure($0, accountsClient: testAccounts) }" : "configure: configure")) { application in
                    try await $_application.withValue(application) {
                        try await function()
                    }
                }
            }
        }

        extension Trait where Self == AppTrait {
            /// Enable this trait to access a fresh instance of your Vapor application for each test at the `app` variable.
            static var withApp: Self { .init() }
        }

        """#
    }

    private func tests() -> String {
        var imports: Set<String> = ["HTTPTypes", "Testing", "Vapor", "VaporTesting"]
        var cases = [
            #"""
                @Test("Test Hello World Route")
                func helloWorld() async throws {
                    try await app.testing { client in
                        let res = try await client.get("/hello")
                        #expect(res.status == .ok)
                        #expect(res.body.string == "Hello, world!")
                    }
                }
            """#
        ]
        if options.wireLibrary {
            imports.insert("ProtobufWireCore")
            imports.insert("WireModels")
            let wire = options.wirePrefix
            cases.append(#"""
                    @Test("Protobuf hello RPC")
                    func protobufHello() async throws {
                        try await app.testing { client in
                            var request = ClientRequest(method: .post, url: "/v1/hello")
                            var hello = \#(wire)HelloRequest()
                            hello.name = "Ada"
                            try request.setProtobuf(hello)

                            let response = try await client.send(request).protobuf(\#(wire)HelloResponse.self)
                            #expect(response.message == "Hello, Ada!")
                            #expect(response.count >= 1)
                        }
                    }

                    @Test("Protobuf errors are ErrorDetail bodies")
                    func protobufError() async throws {
                        try await app.testing { client in
                            var request = ClientRequest(method: .post, url: "/v1/hello")
                            try request.setProtobuf(\#(wire)HelloRequest())

                            let error = await #expect(throws: RemoteServiceError.self) {
                                try await client.send(request).protobuf(\#(wire)HelloResponse.self)
                            }
                            #expect(error?.category == .invalidArgument)
                        }
                    }
                """#)
        }

        return #"""
            \#(imports.sorted().map { "import \($0)" }.joined(separator: "\n"))

            @testable import \#(name)

            @Suite("App Tests", .withApp)
            struct \#(name)Tests {
            \#(cases.joined(separator: "\n\n"))
            }

            /// If the `withApp` test trait is enabled, you can get here
            /// a fresh instance of your Vapor application for each test.
            private var app: Application {
                get throws { try #require(_application) }
            }

            """#
    }

    // MARK: - Authentication

    private func authenticationProto() -> String {
        """
        syntax = "proto3";

        // Signing in to \(name) through accounts. The access token is never in these bodies: sign-in returns it in the
        // X-Updated-Access-Token and X-Updated-Access-Token-Version headers, like every refreshed token, so the
        // ServiceCore client libraries store it the same way. Failures are `servicecore.wire.v1.ErrorDetail` bodies,
        // with an X-Authentication-Error header naming what went wrong.
        package \(options.wirePackage);

        // Where to send someone to sign in at accounts.
        message AuthorizationURLRequest {
            // One of the redirect URIs registered for \(name) in accounts: https only.
            string redirect_uri = 1;
            // An unguessable value the client keeps and checks when accounts redirects back (CSRF protection).
            string state = 2;
        }

        message AuthorizationURLResponse {
            string url = 1;
        }

        // The code accounts redirected back with.
        message SignInRequest {
            string code = 1;
            // The redirect URI the authorisation used.
            string redirect_uri = 2;
        }

        message SignInResponse {
            string account_id = 1;
            repeated string scopes = 2;
        }

        message SignOutRequest {}

        message SignOutResponse {}

        message MeRequest {}

        // Who the access token belongs to.
        message MeResponse {
            string account_id = 1;
            repeated string scopes = 2;
        }

        """
    }

    private func helloController() -> String {
        let wire = options.wirePrefix
        let count = options.usesRecords
            ? "Int64(try await records.recordGreeting(for: request.name).count)"
            : "1"
        let imports = (["ProtobufWireCore", "Vapor", "VaporMacros", "WireModels"] + (options.usesRecords ? ["RecordStore"] : []))
            .sorted().map { "import \($0)" }.joined(separator: "\n")
        return #"""
            \#(imports)

            /// \#(name)'s example RPC.
            ///
            /// Handlers decode their body with `req.protobuf(_:)`, return a message (wrapped in `Protobuf`, or directly
            /// once it conforms to `ProtobufResponseEncodable`), and throw `StandardError`s or their own
            /// `ServiceError`s. `useProtobufErrors` in `configure` turns errors into `ErrorDetail` bodies, and makes
            /// \#(name)'s `ProtobufWireConfiguration` (its request-ID header) apply to every response.
            @Controller
            struct HelloController {\#(options.usesRecords ? "\n    let records: RecordDatabase\n" : "")
                @POST("v1", "hello")
                func hello(req: Request) async throws -> Protobuf<\#(wire)HelloResponse> {
                    let request = try await req.protobuf(\#(wire)HelloRequest.self)
                    guard !request.name.isEmpty else {
                        throw StandardError.invalidArgument("name is required")
                    }
                    var response = \#(wire)HelloResponse()
                    response.message = "Hello, \(request.name)!"
                    response.count = \#(count)
                    return Protobuf(response)
                }
            }

            """#
    }

    private func authenticationController() -> String {
        let wire = options.wirePrefix
        return #"""
            import AuthenticationCore
            import Foundation
            import HTTPTypes
            import ProtobufWireCore
            import Vapor
            import VaporMacros
            import WireModels

            /// Signing people in to \#(name) through accounts.
            ///
            /// 1. The client asks `authorization-url` where to send the person, opens it, and accounts redirects back to
            ///    the redirect URI with `code` and `state`.
            /// 2. The client checks `state` and posts the code to `sign-in`. The access token comes back in the
            ///    `X-Updated-Access-Token` and `X-Updated-Access-Token-Version` headers; the refresh token never leaves
            ///    \#(name).
            /// 3. Every route behind `AuthenticationMiddleware` (`@AuthMiddleware` below) checks the token, refreshes
            ///    it when it has expired, and returns the refreshed one in the same headers. The ServiceCore client
            ///    libraries (`Clients/` in ServiceCore) store tokens and retry.
            @Controller
            struct AuthenticationController {
                /// The account scopes \#(name) asks people to grant. Must be allowed for \#(name)'s OAuth client in accounts.
                static let scopes = ["user.read"]

                let auth: AuthenticationService
                let accounts: AccountsConfiguration

                /// For `@AuthMiddleware`: authenticates the request as an `AuthenticatedAccount`.
                var authentication: AuthenticationMiddleware {
                    AuthenticationMiddleware(service: auth)
                }

                @POST("v1", "auth", "authorization-url")
                func authorizationURL(req: Request) async throws -> Protobuf<\#(wire)AuthorizationURLResponse> {
                    let request = try await req.protobuf(\#(wire)AuthorizationURLRequest.self)
                    guard !request.redirectUri.isEmpty else { throw StandardError.invalidArgument("redirect_uri is required") }
                    var response = \#(wire)AuthorizationURLResponse()
                    response.url = accounts.authorizationURL(
                        redirectURI: request.redirectUri, scopes: Self.scopes,
                        state: request.state.isEmpty ? nil : request.state
                    ).absoluteString
                    return Protobuf(response)
                }

                @POST("v1", "auth", "sign-in")
                func signIn(req: Request) async throws -> Protobuf<\#(wire)SignInResponse> {
                    let request = try await req.protobuf(\#(wire)SignInRequest.self)
                    guard !request.code.isEmpty else { throw StandardError.invalidArgument("code is required") }
                    let session = try await auth.signIn(
                        code: request.code, redirectURI: request.redirectUri.isEmpty ? nil : request.redirectUri
                    )
                    var response = \#(wire)SignInResponse()
                    response.accountID = session.account.id
                    response.scopes = session.account.scopes.sorted()
                    // The token goes in headers, where the client libraries look for it.
                    return Protobuf(response, headers: session.responseHeaders)
                }

                @POST("v1", "auth", "sign-out")
                @AuthMiddleware(AuthenticatedAccount.self, using: { (controller: AuthenticationController) in controller.authentication })
                func signOut(req: Request, account: AuthenticatedAccount) async throws -> Protobuf<\#(wire)SignOutResponse> {
                    try await auth.signOut(accessToken: account.accessToken)
                    return Protobuf(\#(wire)SignOutResponse())
                }

                /// An authenticated route. Key \#(name)'s own per-account data on `account.id`, never on the access
                /// token: tokens change at every refresh.
                @GET("v1", "me")
                @AuthMiddleware(AuthenticatedAccount.self, using: { (controller: AuthenticationController) in controller.authentication })
                func me(req: Request, account: AuthenticatedAccount) async throws -> Protobuf<\#(wire)MeResponse> {
                    var response = \#(wire)MeResponse()
                    response.accountID = account.id
                    response.scopes = account.scopes.sorted()
                    return Protobuf(response)
                }
            }

            """#
    }

    private func fakeAccounts() -> String {
        #"""
        import AuthenticationCore
        import Configuration
        import Foundation
        import Synchronization

        /// Accounts' OAuth endpoints, in memory, behaving as the real ones do: refreshing is a compare-and-set on the
        /// access token's generation, and issuing a new token kills the previous one.
        final class FakeAccounts: AccountsOAuthClient {
            private struct Grant {
                var accessToken: String
                let refreshToken: String
                let subject: String
                var generation: UInt64 = 0
                var expired = false
            }

            private let state = Mutex<(grants: [Grant], codes: [String: String])>(([], [:]))
            private let scopes = ["user.read"]

            /// An authorisation code that signs in as `subject`, as accounts' redirect would carry.
            func code(for subject: String) -> String {
                let code = "code-\(UUID().uuidString)"
                state.withLock { $0.codes[code] = subject }
                return code
            }

            /// Expires an access token, as an hour passing would.
            func expire(_ accessToken: String) {
                state.withLock { state in
                    if let index = state.grants.firstIndex(where: { $0.accessToken == accessToken }) {
                        state.grants[index].expired = true
                    }
                }
            }

            func introspect(accessToken: String) async throws -> TokenIntrospection {
                state.withLock { state in
                    guard let grant = state.grants.first(where: { $0.accessToken == accessToken }), !grant.expired else {
                        return .inactive
                    }
                    return TokenIntrospection(active: true, subject: grant.subject, scopes: scopes, generation: grant.generation)
                }
            }

            func refresh(refreshToken: String, expectedGeneration: UInt64) async throws -> TokenGrant {
                try state.withLock { state in
                    guard let index = state.grants.firstIndex(where: { $0.refreshToken == refreshToken }) else {
                        throw AccountsOAuthError.rejected(code: "invalid_grant", description: nil)
                    }
                    var grant = state.grants[index]
                    if expectedGeneration == grant.generation {
                        grant.accessToken = "access-\(UUID().uuidString)"
                        grant.generation += 1
                        grant.expired = false
                        state.grants[index] = grant
                    } else if expectedGeneration + 1 != grant.generation {
                        throw AccountsOAuthError.rejected(code: "stale_generation", description: nil)
                    }
                    return TokenGrant(
                        accessToken: grant.accessToken, expiresIn: 3600, refreshToken: grant.refreshToken,
                        scopes: scopes, generation: grant.generation
                    )
                }
            }

            func exchange(code: String, redirectURI: String?) async throws -> TokenGrant {
                try state.withLock { state in
                    guard let subject = state.codes.removeValue(forKey: code) else {
                        throw AccountsOAuthError.rejected(code: "invalid_grant", description: nil)
                    }
                    let grant = Grant(
                        accessToken: "access-\(UUID().uuidString)", refreshToken: "refresh-\(UUID().uuidString)",
                        subject: subject
                    )
                    state.grants.append(grant)
                    return TokenGrant(
                        accessToken: grant.accessToken, expiresIn: 3600, refreshToken: grant.refreshToken,
                        scopes: scopes, generation: 0
                    )
                }
            }
        }

        /// The accounts every test app talks to.
        let testAccounts = FakeAccounts()

        /// Accounts configuration for tests, ahead of the environment.
        let testConfiguration = ConfigReader(providers: [
            InMemoryProvider(values: [
                "accounts.client.identifier": "\#(options.name.kebabName)",
                "accounts.client.secret": "test-secret",
                "accounts.frontend.url": "https://accounts.example",
                "accounts.api.url": "https://api.accounts.example",
            ]),
            EnvironmentVariablesProvider(),
        ])

        """#
    }

    private func authenticationTests() -> String {
        let wire = options.wirePrefix
        return #"""
            import AuthenticationCore
            import Foundation
            import HTTPTypes
            import ProtobufWireCore
            import Testing
            import Vapor
            import VaporTesting
            import WireModels

            @testable import \#(name)

            @Suite("Authentication", .withApp)
            struct AuthenticationTests {
                @Test("Signing in returns the token in headers, and it works")
                func signIn() async throws {
                    try await app.testing { client in
                        let token = try await signIn(client, as: "ada")
                        let response = try await me(client, token: token)
                        #expect(response.status == .ok)
                        #expect(try await response.protobuf(\#(wire)MeResponse.self).accountID == "ada")
                    }
                }

                @Test("A code works once")
                func codesAreSingleUse() async throws {
                    try await app.testing { client in
                        let code = testAccounts.code(for: "ada")
                        _ = try await sendSignIn(client, code: code)
                        let reused = try await sendSignIn(client, code: code)
                        #expect(reused.status == .badRequest)
                        #expect(reused.headers[.authenticationError] == "invalid_authorization_code")
                    }
                }

                @Test("Expired tokens are refreshed, and the old one is refused")
                func refresh() async throws {
                    try await app.testing { client in
                        let old = try await signIn(client, as: "grace")
                        testAccounts.expire(old)

                        let refreshed = try await me(client, token: old)
                        #expect(refreshed.status == .ok)
                        let new = try #require(refreshed.headers[.updatedAccessToken])
                        #expect(refreshed.headers[.updatedAccessTokenVersion].flatMap(AccessTokenVersion.init)?.generation == 1)

                        let stale = try await me(client, token: old)
                        #expect(stale.status == .unauthorized)
                        #expect(stale.headers[.authenticationError] == "invalid_access_token")

                        let again = try await me(client, token: new)
                        #expect(again.status == .ok)
                        #expect(again.headers[.updatedAccessToken] == nil)
                    }
                }

                @Test("Signing out forgets the session")
                func signOut() async throws {
                    try await app.testing { client in
                        let token = try await signIn(client, as: "alan")
                        var request = ClientRequest(method: .post, url: "/v1/auth/sign-out")
                        request.headers.bearerAuthorization = BearerAuthorization(token: token)
                        try request.setProtobuf(\#(wire)SignOutRequest())
                        #expect(try await client.send(request).status == .ok)

                        // Once the token expires there is no session to refresh it from.
                        testAccounts.expire(token)
                        let response = try await me(client, token: token)
                        #expect(response.status == .unauthorized)
                        #expect(response.headers[.authenticationError] == "invalid_access_token")
                    }
                }

                @Test("Requests without a token are refused")
                func missingToken() async throws {
                    try await app.testing { client in
                        let response = try await client.send(ClientRequest(method: .get, url: "/v1/me"))
                        #expect(response.status == .unauthorized)
                        #expect(response.headers[.authenticationError] == "missing_access_token")
                    }
                }

                @Test("The authorization URL points at accounts")
                func authorizationURL() async throws {
                    try await app.testing { client in
                        var request = ClientRequest(method: .post, url: "/v1/auth/authorization-url")
                        var body = \#(wire)AuthorizationURLRequest()
                        body.redirectUri = "https://app.example/signed-in"
                        body.state = "xyz"
                        try request.setProtobuf(body)
                        let url = try await client.send(request).protobuf(\#(wire)AuthorizationURLResponse.self).url
                        let components = try #require(URLComponents(string: url))
                        #expect(components.host == "accounts.example")
                        #expect(components.path == "/authorize")
                        #expect(components.queryItems?.contains(URLQueryItem(name: "client_id", value: "\#(options.name.kebabName)")) == true)
                        #expect(components.queryItems?.contains(URLQueryItem(name: "state", value: "xyz")) == true)
                    }
                }

                private func sendSignIn(_ client: some Client, code: String) async throws -> ClientResponse {
                    var request = ClientRequest(method: .post, url: "/v1/auth/sign-in")
                    var body = \#(wire)SignInRequest()
                    body.code = code
                    body.redirectUri = "https://app.example/signed-in"
                    try request.setProtobuf(body)
                    return try await client.send(request)
                }

                /// Signs in as `subject` and returns the access token.
                private func signIn(_ client: some Client, as subject: String) async throws -> String {
                    let response = try await sendSignIn(client, code: testAccounts.code(for: subject))
                    #expect(response.status == .ok)
                    #expect(response.headers[.updatedAccessTokenVersion] != nil)
                    let token = try #require(response.headers[.updatedAccessToken])
                    #expect(try await response.protobuf(\#(wire)SignInResponse.self).accountID == subject)
                    return token
                }

                private func me(_ client: some Client, token: String) async throws -> ClientResponse {
                    var request = ClientRequest(method: .get, url: "/v1/me")
                    request.headers.bearerAuthorization = BearerAuthorization(token: token)
                    return try await client.send(request)
                }
            }

            private var app: Application {
                get throws { try #require(_application) }
            }

            """#
    }

    // MARK: - Project files

    private func gitignore() -> String {
        var lines = [
            "Packages", ".build", "xcuserdata", "*.xcodeproj", "DerivedData/", ".DS_Store", "db.sqlite",
            ".swiftpm", ".env", ".env.*", "!.env.example", "default.profraw",
        ]
        if options.blobStore {
            lines.append("# The filesystem blob backend's default root.")
            lines.append("/blobs")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func devcontainer() -> String {
        #"""
        {
            "name": "\#(name)",
            "image": "swift:6.4-resolute",
            "features": {
                "ghcr.io/devcontainers/features/common-utils:2": {
                    "installZsh": "false",
                    "username": "vscode",
                    "upgradePackages": "false"
                },
                "ghcr.io/devcontainers/features/git:1": {
                    "version": "os-provided",
                    "ppa": "false"
                }
            },
            "runArgs": [
                "--cap-add=SYS_PTRACE",
                "--security-opt",
                "seccomp=unconfined"
            ],
            // Configure tool-specific properties.
            "customizations": {
                // Configure properties specific to VS Code.
                "vscode": {
                    // Set *default* container specific settings.json values on container create.
                    "settings": {
                        "swift.path": "/usr/bin",
                        "lldb.library": "/usr/lib/liblldb.so"
                    },
                    // Add the IDs of extensions you want installed when the container is created.
                    "extensions": [
                        "swiftlang.swift-vscode",
                        "Vapor.vapor-vscode"
                    ]
                }
            },
            // Use 'forwardPorts' to make a list of ports inside the container available locally.
            // "forwardPorts": [],

            // Set `remoteUser` to `root` to connect as root instead. More info: https://aka.ms/vscode-remote/containers/non-root.
            "remoteUser": "vscode"
        }

        """#
    }

    private func dockerCompose() -> String {
        var environment = ["  LOG_LEVEL: ${LOG_LEVEL:-debug}"]
        var volumes: [String] = []
        if options.usesFDB {
            environment.append("  FDB_TENANT: ${FDB_TENANT:-\(options.name.kebabName)}")
            environment.append("  # The cluster file of the FoundationDB cluster to use, mounted below.")
            environment.append("  FDB_CLUSTER_FILE: /etc/foundationdb/fdb.cluster")
            volumes.append("      - ${FDB_CLUSTER_FILE_HOST:-./fdb.cluster}:/etc/foundationdb/fdb.cluster:ro")
        }
        if options.authentication {
            environment.append("  # \(name)'s OAuth client in accounts (Services → OAuth), and where accounts runs.")
            environment.append("  ACCOUNTS_CLIENT_IDENTIFIER: ${ACCOUNTS_CLIENT_IDENTIFIER}")
            environment.append("  ACCOUNTS_CLIENT_SECRET: ${ACCOUNTS_CLIENT_SECRET}")
            environment.append("  ACCOUNTS_FRONTEND_URL: ${ACCOUNTS_FRONTEND_URL}")
            environment.append("  ACCOUNTS_API_URL: ${ACCOUNTS_API_URL}")
        }
        if options.blobStore {
            environment.append("  STORAGE_BLOBS_BACKEND: ${STORAGE_BLOBS_BACKEND:-filesystem}")
            environment.append("  STORAGE_BLOBS_ROOT: /app/blobs")
            volumes.append("      - blobs:/app/blobs")
        }
        let volumeSection = volumes.isEmpty ? "" : "\n    volumes:\n" + volumes.joined(separator: "\n")
        let namedVolumes = options.blobStore ? "\n\nvolumes:\n  blobs:" : ""

        return """
            # Docker Compose file for Vapor
            #
            # Install Docker on your system to run and test
            # your Vapor app in a production-like environment.
            #
            # Note: This file is intended for testing and does not
            # implement best practices for a production deployment.
            #
            # Learn more: https://docs.docker.com/compose/reference/
            #
            #   Build images: docker compose build
            #      Start app: docker compose up app
            #       Stop all: docker compose down
            #

            x-shared_environment: &shared_environment
            \(environment.joined(separator: "\n"))
            \("  ")
            services:
              app:
                image: \(options.name.kebabName):latest
                build:
                  context: .
                environment:
                  <<: *shared_environment
                ports:
                  - '8080:8080'\(volumeSection)
                # user: '0' # uncomment to run as root for testing purposes even though Dockerfile defines 'vapor' user.
                command: ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]\(namedVolumes)

            """
    }

    /// The template's Dockerfile, unchanged apart from the product name.
    private func dockerfile() -> String {
        #"""
        # ================================
        # Build image
        # ================================
        FROM swift:6.4-noble AS build

        # Install OS updates\#(options.usesProtobuf ? ", and protoc for the SwiftProtobuf build plugin" : "")
        RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
            && apt-get -q update \
            && apt-get -q dist-upgrade -y \
            && apt-get install -y libjemalloc-dev\#(options.usesProtobuf ? " protobuf-compiler" : "")

        # Set up a build area
        WORKDIR /build

        # First just resolve dependencies.
        # This creates a cached layer that can be reused
        # as long as your Package.swift/Package.resolved
        # files do not change.
        COPY ./Package.* ./
        RUN swift package resolve \
                $([ -f ./Package.resolved ] && echo "--force-resolved-versions" || true)

        # Copy entire repo into container
        COPY . .

        RUN mkdir /staging

        # Build the application, with optimizations, with static linking, and using jemalloc
        # N.B.: The static version of jemalloc is incompatible with the static Swift runtime.
        RUN --mount=type=cache,target=/build/.build \
            swift build -c release \
                --product \#(name) \
                --static-swift-stdlib \
                -Xlinker -ljemalloc && \
            # Copy main executable to staging area
            cp "$(swift build -c release --show-bin-path)/\#(name)" /staging && \
            # Copy resources bundled by SPM to staging area
            find -L "$(swift build -c release --show-bin-path)" -regex '.*\.resources$' -exec cp -Ra {} /staging \;


        # Switch to the staging area
        WORKDIR /staging

        # Copy static swift backtracer binary to staging area
        RUN cp "/usr/libexec/swift/linux/swift-backtrace-static" ./

        # Copy any resources from the public directory and views directory if the directories exist
        # Ensure that by default, neither the directory nor any of its contents are writable.
        RUN [ -d /build/Public ] && { mv /build/Public ./Public && chmod -R a-w ./Public; } || true
        RUN [ -d /build/Resources ] && { mv /build/Resources ./Resources && chmod -R a-w ./Resources; } || true

        # ================================
        # Run image
        # ================================
        FROM ubuntu:noble

        # Make sure all system packages are up to date, and install only essential packages.
        RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
            && apt-get -q update \
            && apt-get -q dist-upgrade -y \
            && apt-get -q install -y \
              libjemalloc2 \
              ca-certificates \
              tzdata \
        # If your app or its dependencies import FoundationNetworking, also install `libcurl4`.
              # libcurl4 \
        # If your app or its dependencies import FoundationXML, also install `libxml2`.
              # libxml2 \
            && rm -r /var/lib/apt/lists/*

        # Create a vapor user and group with /app as its home directory
        RUN useradd --user-group --create-home --system --skel /dev/null --home-dir /app vapor

        # Switch to the new home directory
        WORKDIR /app

        # Copy built executable and any staged resources from builder
        COPY --from=build --chown=vapor:vapor /staging /app

        # Provide configuration needed by the built-in crash reporter and some sensible default behaviors.
        ENV SWIFT_BACKTRACE=enable=yes,sanitize=yes,threads=all,images=all,interactive=no,swift-backtrace=./swift-backtrace-static

        # Ensure all further commands run as the vapor user
        USER vapor:vapor

        # Let Docker bind to port 8080
        EXPOSE 8080

        # Start the Vapor service when the image is run, default to listening on 8080 in production environment
        ENTRYPOINT ["./\#(name)"]
        CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]

        """#
    }

    /// The Accounts service's Dockerfile: the FoundationDB client in both
    /// stages, and SSH for the private bindings.
    private func fdbDockerfile() -> String {
        #"""
        # syntax=docker/dockerfile:1.7
        #
        # \#(name) as a Linux container. Build with an SSH agent, which fetches the private fdb-swift-bindings dependency:
        #
        #   docker build --ssh default -t \#(options.name.kebabName) .

        ARG SWIFT_VERSION=6.4
        ARG FDB_VERSION=7.3.77

        # MARK: - Build
        FROM swift:${SWIFT_VERSION}-noble AS build
        ARG FDB_VERSION
        ARG TARGETARCH

        # FoundationDB's C client (library and headers), which must match the server's major.minor version, plus the
        # pkg-config file the bindings' CFoundationDB module looks for (FoundationDB doesn't ship one). protoc is for the
        # SwiftProtobuf build plugin.
        RUN export DEBIAN_FRONTEND=noninteractive \
            && apt-get update -q && apt-get install -yq --no-install-recommends curl ca-certificates protobuf-compiler openssh-client \
            && arch="$([ "$TARGETARCH" = arm64 ] && echo aarch64 || echo amd64)" \
            && curl -fsSL -o /tmp/fdb-clients.deb "https://github.com/apple/foundationdb/releases/download/${FDB_VERSION}/foundationdb-clients_${FDB_VERSION}-1_${arch}.deb" \
            && apt-get install -yq --no-install-recommends /tmp/fdb-clients.deb && rm /tmp/fdb-clients.deb \
            && mkdir -p /usr/lib/pkgconfig \
            && printf 'prefix=/usr\nincludedir=${prefix}/include\nlibdir=${prefix}/lib\n\nName: CFoundationDB\nDescription: The FoundationDB C client\nVersion: %s\nCflags: -I${includedir}\nLibs: -L${libdir} -lfdb_c\n' "$FDB_VERSION" > /usr/lib/pkgconfig/libfdb.pc \
            && mkdir -p -m 700 /root/.ssh && ssh-keyscan -t ed25519 github.com >> /root/.ssh/known_hosts \
            && rm -rf /var/lib/apt/lists/*

        WORKDIR /build

        # Resolve first, so source edits don't refetch dependencies.
        COPY Package.swift Package.resolved ./
        RUN --mount=type=ssh --mount=type=cache,target=/build/.build swift package resolve

        COPY Sources Sources
        COPY Tests Tests
        RUN --mount=type=ssh --mount=type=cache,target=/build/.build \
            swift build -c release --product \#(name) --static-swift-stdlib \
            && mkdir -p /staging \
            && cp "$(swift build -c release --show-bin-path)/\#(name)" /staging/

        # MARK: - Run
        FROM ubuntu:noble
        ARG FDB_VERSION
        ARG TARGETARCH

        RUN export DEBIAN_FRONTEND=noninteractive \
            && apt-get update -q && apt-get install -yq --no-install-recommends ca-certificates tzdata curl \
            && arch="$([ "$TARGETARCH" = arm64 ] && echo aarch64 || echo amd64)" \
            && curl -fsSL -o /tmp/fdb-clients.deb "https://github.com/apple/foundationdb/releases/download/${FDB_VERSION}/foundationdb-clients_${FDB_VERSION}-1_${arch}.deb" \
            && apt-get install -yq --no-install-recommends /tmp/fdb-clients.deb && rm /tmp/fdb-clients.deb \
            && apt-get purge -yq curl && apt-get autoremove -yq && rm -rf /var/lib/apt/lists/* \
            && useradd --system --uid 10001 --user-group --create-home --home-dir /app --shell /usr/sbin/nologin vapor

        WORKDIR /app
        COPY --from=build --chown=vapor:vapor /staging/\#(name) /app/\#(name)

        # Numeric, so Kubernetes can verify `runAsNonRoot` without resolving the name.
        USER 10001:10001
        EXPOSE 8080
        ENTRYPOINT ["/app/\#(name)"]
        CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]

        """#
    }

    private func readme() -> String {
        var sections: [String] = []
        if options.usesFDB {
            sections.append("""
                ### FoundationDB

                \(name) keeps its data in the FoundationDB tenant `\(options.name.kebabName)`\(options.usesRecords ? ", as Record Layer records (schema in `Sources/\(name)/Models/Database/Schema.swift`)" : "") and creates the tenant on first start. Configure it with `FDB_CLUSTER_FILE` and `FDB_TENANT`. Tests run against the local cluster, so they need FoundationDB installed and running with tenants enabled.
                """)
        }
        if options.blobStore {
            sections.append("""
                ### Blob storage

                Blobs go to `./blobs` by default. Set `STORAGE_BLOBS_BACKEND=s3` and `STORAGE_BLOBS_S3_ENDPOINT`, `…_BUCKET`, `…_ACCESS_KEY_ID`, `…_SECRET_ACCESS_KEY` to use an S3-compatible bucket instead.
                """)
        }
        if options.wireLibrary {
            sections.append("""
                ### Wire models

                The `WireModels` library holds the protobuf messages clients exchange with \(name) (`Sources/WireModels/*.proto`). Clients can depend on it directly. Errors are `servicecore.wire.v1.ErrorDetail` bodies.
                """)
        }
        if options.authentication {
            sections.append("""
                ### Authentication

                People sign in through accounts (OAuth); see `Sources/\(name)/Controllers/AuthenticationController.swift` and `Sources/WireModels/Authentication.proto`. Register \(name) in accounts (Services → OAuth) with its https redirect URIs and the `user.read` scope, then set `ACCOUNTS_CLIENT_IDENTIFIER`, `ACCOUNTS_CLIENT_SECRET`, `ACCOUNTS_FRONTEND_URL` and `ACCOUNTS_API_URL`.

                | Route | |
                |---|---|
                | `POST /v1/auth/authorization-url` | where to send someone to sign in |
                | `POST /v1/auth/sign-in` | exchanges the code; the access token comes back in `X-Updated-Access-Token` and `X-Updated-Access-Token-Version` |
                | `POST /v1/auth/sign-out` | forgets the session |
                | `GET /v1/me` | an example authenticated route |

                Expired tokens are refreshed on the next request and returned in the same headers. Clients should use ServiceCore's client libraries (`Clients/swift`, `Clients/typescript`), which store tokens and retry correctly; the rules are in ServiceCore's README under "How clients work". \(options.usesFDB ? "Sessions are kept in this service's FoundationDB tenant." : "Sessions are kept in memory, so a restart signs everyone out: use a persistent `SessionStore` before production.") Tests use a fake accounts (`Tests/\(name)Tests/FakeAccounts.swift`).
                """)
        }
        if options.usesServiceCore, case .path = options.serviceCore {
            sections.append("""
                ### ServiceCore

                ServiceCore is a local path dependency, so it is not inside the Docker build context. For container builds, switch `Package.swift` to its git URL.
                """)
        }

        return """
            # \(name)

            💧 A project built with the Vapor web framework\(options.usesServiceCore ? " and ServiceCore (\(options.serviceCoreProducts.joined(separator: ", ")))" : "").

            ## Getting Started

            To build the project using the Swift Package Manager, run the following command in the terminal from the root of the project:
            ```bash
            swift build
            ```

            To run the project and start the server, use the following command:
            ```bash
            swift run
            ```

            To execute tests, use the following command:
            ```bash
            swift test
            ```
            \(sections.isEmpty ? "" : "\n" + sections.joined(separator: "\n\n") + "\n")
            ### See more

            - [Vapor Website](https://vapor.codes)
            - [Vapor Documentation](https://docs.vapor.codes)
            - [Vapor GitHub](https://github.com/vapor)
            - [Vapor Community maintained packages](https://github.com/vapor-community)

            """
    }
}

extension String {
    var lowercasedFirst: String {
        prefix(1).lowercased() + dropFirst()
    }
}
