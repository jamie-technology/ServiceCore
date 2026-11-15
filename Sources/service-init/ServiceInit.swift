import ArgumentParser
import Foundation

/// Scaffolds a new Vapor 5 service on ServiceCore.
///
/// The output matches `vapor new <name> --branch vapor5` file for file, with
/// the chosen ServiceCore libraries wired in on top.
@main
struct ServiceInit: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "service-init",
        abstract: "Create a new Vapor 5 service that uses ServiceCore.",
        discussion: """
            Examples:
              service-init Mailroom
              service-init Mailroom --fdb=records --protobuf-wire-library --blob-store
              service-init Mailroom --fdb=records --authentication
              service-init Mailroom --fdb=kv --service-core-path ../ServiceCore
            """
    )

    enum FoundationDBMode: String, ExpressibleByArgument, CaseIterable {
        /// Raw key-value access through FoundationDBCore.
        case kv
        /// The Record Layer through RecordStore.
        case records
    }

    @Argument(help: "The service's name. Becomes the package, executable target and test target names.")
    var name: String

    @Option(name: .shortAndLong, help: "Where to create the service. Defaults to ./<name>.")
    var output: String?

    @Option(help: "Wire up FoundationDB: 'kv' for raw key-value access, 'records' for the Record Layer.")
    var fdb: FoundationDBMode?

    @Flag(help: "Scaffold a 'WireModels' library with swift-protobuf, and serve it with ProtobufWireCore.")
    var protobufWireLibrary = false

    @Flag(help: "Wire up a BlobStore (filesystem or S3, chosen by configuration).")
    var blobStore = false

    @Flag(help: """
        Sign people in through accounts (OAuth): an AuthenticationController, AuthenticationMiddleware and token \
        refresh. Implies --protobuf-wire-library. Sessions go in FoundationDB with --fdb, otherwise in memory.
        """)
    var authentication = false

    /// Where ServiceCore lives. Generated services depend on it by this URL
    /// unless told otherwise, so they build anywhere, Docker included.
    static let defaultServiceCoreURL = "https://github.com/jamie-technology/ServiceCore.git"

    @Option(help: "The git URL to depend on ServiceCore by.")
    var serviceCoreURL = ServiceInit.defaultServiceCoreURL

    @Option(help: "The ServiceCore branch to depend on.")
    var serviceCoreBranch = "main"

    @Option(help: """
        Depend on a local ServiceCore checkout at this path instead of the git URL, to develop ServiceCore \
        alongside the service. Not for anything built in Docker.
        """)
    var serviceCorePath: String?

    @Flag(inversion: .prefixedNo, help: "Create a git repository in the new service.")
    var git = true

    @Flag(help: "Write into the output directory even if it is not empty.")
    var force = false

    func validate() throws {
        guard ServiceName(name) != nil else {
            throw ValidationError(
                "'\(name)' is not a usable name: start with a letter and use only letters and digits."
            )
        }
        if serviceCoreURL != Self.defaultServiceCoreURL || serviceCoreBranch != "main", serviceCorePath != nil {
            throw ValidationError("--service-core-path replaces the git URL: pass it, or --service-core-url/--service-core-branch, not both.")
        }
    }

    func run() throws {
        let name = ServiceName(self.name)!
        let directory = URL(fileURLWithPath: output ?? name.typeName, isDirectory: true).standardizedFileURL

        let fileManager = FileManager.default
        if let existing = try? fileManager.contentsOfDirectory(atPath: directory.path), !existing.isEmpty, !force {
            throw ValidationError("\(directory.path) is not empty; pass --force to write into it anyway.")
        }

        let options = ScaffoldOptions(
            name: name,
            fdb: fdb,
            wireLibrary: protobufWireLibrary || authentication,
            blobStore: blobStore,
            authentication: authentication,
            serviceCore: serviceCoreReference(relativeTo: directory)
        )

        let files = Scaffold(options).files()
        for (path, contents) in files.sorted(by: { $0.key < $1.key }) {
            let file = directory.appending(path: path)
            try fileManager.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try contents.write(to: file, atomically: true, encoding: .utf8)
            print("  created \(path)")
        }

        if git {
            try runGit(["init", "--quiet"], in: directory)
        }

        if authentication && !protobufWireLibrary {
            print("\nnote: --authentication added the WireModels library (--protobuf-wire-library) for its messages.")
        }
        if authentication && fdb == nil {
            print("warning: without --fdb, sessions are kept in memory: every restart signs everyone out.")
        }

        print("""

            \(name.typeName) created at \(directory.path).
            \(options.usesServiceCore ? "ServiceCore libraries: \(options.serviceCoreProducts.joined(separator: ", "))\n" : "")
            Next:
              cd \(directory.path)
              swift build
            """)
    }

    private func serviceCoreReference(relativeTo directory: URL) -> ServiceCoreReference {
        guard let serviceCorePath else {
            return .url(serviceCoreURL, branch: serviceCoreBranch)
        }
        let path = URL(fileURLWithPath: serviceCorePath, isDirectory: true)
        return .path(relativePath(from: directory, to: path.standardizedFileURL))
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            print("warning: git \(arguments.joined(separator: " ")) failed; the service was still created.")
        }
    }
}

/// `to`, relative to `from`, or absolute when they share nothing but `/`.
func relativePath(from base: URL, to target: URL) -> String {
    let baseComponents = base.standardizedFileURL.pathComponents
    let targetComponents = target.standardizedFileURL.pathComponents
    var common = 0
    while common < min(baseComponents.count, targetComponents.count),
          baseComponents[common] == targetComponents[common] {
        common += 1
    }
    guard common > 1 else { return target.standardizedFileURL.path }
    let up = Array(repeating: "..", count: baseComponents.count - common)
    let down = targetComponents[common...]
    let joined = (up + down).joined(separator: "/")
    return joined.isEmpty ? "." : joined
}
