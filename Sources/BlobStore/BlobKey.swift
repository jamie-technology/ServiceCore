/// The address of a blob: a scope, the hex SHA-256 of its bytes, and
/// optionally which incarnation of that content it is.
///
/// Content addressing makes `put` idempotent, so concurrent uploads of the same
/// content cannot conflict and a re-run of an interrupted write is a no-op
/// rather than a duplicate. It also lets the server verify integrity without
/// being able to read encrypted content.
///
/// **The scope is part of the address, not decoration.** Without it the store
/// is one namespace shared by every tenant, so an account that learned another
/// scope's content could write over an object it has no access to. It also
/// keeps collection local: deleting a blob a scope stops referencing never
/// requires knowing that no *other* scope still does. There is no initializer
/// that takes a digest alone, so forgetting the scope is impossible rather than
/// left to a reviewer.
///
/// **The token makes deletion safe.** A `put` happens outside any transaction,
/// so it cannot be ordered against a concurrent `delete` of the same content.
/// Allocate a fresh token (``newToken()``) when the database record that owns
/// the blob is created and keep it on that record: a late delete then names the
/// path of an incarnation nobody will write again, so it cannot reach the bytes
/// of the next one however the two interleave. Services that never delete
/// blobs can leave the token out.
public struct BlobKey: Sendable, Hashable, CustomStringConvertible {
    public let scope: String
    public let hex: String
    public let token: String?

    /// Fails for anything that is not a valid scope, a 64-character lowercase
    /// hex digest, and (if given) a token of the shape ``newToken()`` issues.
    ///
    /// Validated rather than trusted because all three become a filesystem
    /// path and an S3 object key: an unchecked one would be a path-traversal
    /// hole.
    public init?(scope: String, hex: String, token: String? = nil) {
        guard Self.isValidAddress(scope: scope, hex: hex) else { return nil }
        if let token, !Self.isValidToken(token) { return nil }
        self.scope = scope
        self.hex = hex
        self.token = token
    }

    /// Whether a scope and digest could name a blob, without deciding which
    /// incarnation. For validating an address a client offered long before it
    /// is known which incarnation will be written.
    public static func isValidAddress(scope: String, hex: String) -> Bool {
        isValidScope(scope) && isValidDigest(hex)
    }

    /// Scopes are service-generated identifiers, so this guards against a
    /// malformed one reaching a path rather than parsing anything.
    public static func isValidScope(_ scope: String) -> Bool {
        guard !scope.isEmpty, scope.count <= 128 else { return false }
        return scope.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    public static func isValidDigest(_ hex: String) -> Bool {
        hex.count == 64 && hex.allSatisfy(isLowercaseHexDigit)
    }

    public static func isValidToken(_ token: String) -> Bool {
        token.count == 32 && token.allSatisfy(isLowercaseHexDigit)
    }

    /// A token for a newly created record: 16 random bytes as lowercase hex.
    public static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in
            let byte = UInt8.random(in: .min ... .max, using: &generator)
            return String(byte, radix: 16).leftPadded(to: 2)
        }.joined()
    }

    /// Scope first, then sharded two levels by digest prefix so no single
    /// directory or S3 prefix accumulates millions of entries, then the token,
    /// so two incarnations of one address sort together.
    public var shardedPath: String {
        let first = hex.prefix(2)
        let second = hex.dropFirst(2).prefix(2)
        return "\(scope)/\(first)/\(second)/\(fileName)"
    }

    /// Every blob in a scope lives under this prefix, which is what makes
    /// dropping a scope's content a prefix operation.
    public var scopePrefix: String { "\(scope)/" }

    var fileName: String {
        token.map { "\(hex).\($0)" } ?? hex
    }

    public var description: String { "\(scope)/\(fileName)" }

    private static func isLowercaseHexDigit(_ character: Character) -> Bool {
        character.isASCII && character.isHexDigit && !character.isUppercase
    }
}

extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
