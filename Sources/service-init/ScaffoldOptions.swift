/// A service name, in the spellings each place needs.
struct ServiceName: Equatable {
    /// As given: the package, executable target and module name. `MyMail2Service`
    let typeName: String
    /// Lowercase words joined by `_`, for protobuf packages. `my_mail2_service`
    let snakeName: String
    /// Lowercase words joined by `-`, for tenants and images. `my-mail2-service`
    let kebabName: String

    init?(_ name: String) {
        guard let first = name.unicodeScalars.first,
              first.properties.isAlphabetic, first.isASCII,
              name.unicodeScalars.allSatisfy({ $0.isASCII && $0.properties.isAlphabetic || ("0"..."9").contains($0) })
        else { return nil }
        typeName = name

        // A new word starts at an uppercase letter that follows a lowercase
        // letter or a digit: `MyMail2Service` → my, mail2, service.
        var words: [String] = []
        var current = ""
        var previous: Character?
        for character in name {
            if character.isUppercase, let previous, previous.isLowercase || previous.isNumber {
                words.append(current)
                current = ""
            }
            current.append(character)
            previous = character
        }
        words.append(current)
        snakeName = words.map { $0.lowercased() }.joined(separator: "_")
        kebabName = words.map { $0.lowercased() }.joined(separator: "-")
    }

    /// The Swift type prefix protoc-gen-swift derives from a proto package:
    /// each `_`-separated word capitalised, then `_` between package levels.
    /// `my_mail2_service_wire` → `MyMail2ServiceWire_`
    static func protobufPrefix(forPackage package: String) -> String {
        package.split(separator: ".").map { level in
            level.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        }.joined(separator: "_") + "_"
    }
}

enum ServiceCoreReference: Equatable {
    case path(String)
    case url(String, branch: String)

    var packageDeclaration: String {
        switch self {
        case .path(let path):
            ".package(path: \"\(path)\")"
        case .url(let url, let branch):
            ".package(url: \"\(url)\", branch: \"\(branch)\")"
        }
    }
}

struct ScaffoldOptions {
    var name: ServiceName
    var fdb: ServiceInit.FoundationDBMode?
    var wireLibrary: Bool
    var blobStore: Bool
    var authentication: Bool = false
    var serviceCore: ServiceCoreReference

    var usesFDB: Bool { fdb != nil }
    var usesRecords: Bool { fdb == .records }
    var usesProtobuf: Bool { usesRecords || wireLibrary }
    /// Whether the FoundationDB bindings need their Record Layer trait: for
    /// the service's records, or for the authentication session store.
    var usesRecordLayer: Bool { usesRecords || (authentication && usesFDB) }
    /// Whether routes need state built at startup.
    var hasServices: Bool { usesFDB || blobStore || authentication }
    var usesServiceCore: Bool { !serviceCoreProducts.isEmpty }

    var serviceCoreProducts: [String] {
        var products: [String] = []
        if usesFDB { products.append("FoundationDBCore") }
        if usesRecords { products.append("RecordStore") }
        if blobStore { products.append("BlobStore") }
        if wireLibrary { products.append("ProtobufWireCore") }
        if authentication { products.append("AuthenticationCore") }
        if authentication && usesFDB { products.append("AuthenticationFoundationDB") }
        return products
    }

    /// The proto package and Swift prefix of the WireModels messages.
    var wirePackage: String { "\(name.snakeName)_wire" }
    var wirePrefix: String { ServiceName.protobufPrefix(forPackage: wirePackage) }

    /// The proto package and Swift prefix of the database records.
    var databasePackage: String { "\(name.snakeName)_db" }
    var databasePrefix: String { ServiceName.protobufPrefix(forPackage: databasePackage) }
}
