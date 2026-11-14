import Foundation
public import FDBRecordLayer
public import FoundationDB
public import SwiftProtobuf

extension FDBRecordVersion {
    /// The version as clients see it: unpadded base64url, opaque, sent back
    /// unchanged to say which version an edit is based on.
    public var base64URLEncoded: String {
        Base64URL.encode(bytes)
    }

    /// Reads a version a client sent back. `nil` if it is not valid base64url
    /// or not the length of a record version.
    public init?(base64URLEncoded string: String) {
        guard let bytes = Base64URL.decode(string),
              bytes.count == FDBRecordVersion.globalVersionLength + FDBRecordVersion.localVersionLength
        else { return nil }
        self.init(bytes: bytes)
    }
}

extension FDBRecordStore {
    /// Loads a record, checking the client edited the version that is stored.
    ///
    /// The read half of optimistic concurrency, for edits that are not a plain
    /// replace (merging fields, appending to a list). Saving the result with
    /// `save(_:ifVersionMatches:)` is the write half.
    ///
    /// - Returns: The stored record, or `nil` if there is none.
    /// - Throws: `RecordStoreError.versionMismatch` if a record exists but at
    ///   a different version than `expected`.
    public func load<M: SwiftProtobuf.Message & Sendable>(
        _ type: M.Type, primaryKey: Tuple, expecting expected: FDBRecordVersion
    ) async throws -> FDBStoredRecord<M>? {
        guard let stored = try await load(type, primaryKey: primaryKey) else { return nil }
        guard stored.version == expected else { throw RecordStoreError.versionMismatch }
        return stored
    }
}

extension RecordStoreError {
    /// Whether the record changed under the caller. Not retryable: the caller
    /// has to re-read and decide, and retrying blindly would just lose again.
    public var isConflict: Bool {
        if case .versionMismatch = self { return true }
        return false
    }

    /// Whether the write collided with a record that already exists, by
    /// primary key or by a unique index.
    public var isAlreadyExists: Bool {
        switch self {
        case .recordAlreadyExists, .uniquenessViolation: true
        default: false
        }
    }

    /// Whether an update found nothing to update.
    public var isNotFound: Bool {
        if case .recordDoesNotExist = self { return true }
        return false
    }
}

/// Unpadded base64url (RFC 4648 §5), the encoding versions and cursors use in
/// URLs and JSON.
public enum Base64URL {
    public static func encode(_ bytes: some Sequence<UInt8>) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ string: String) -> [UInt8]? {
        guard string.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        guard remainder != 1 else { return nil }
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64).map(Array.init)
    }
}
