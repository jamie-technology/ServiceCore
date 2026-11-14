public import Foundation

public enum BlobStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case notFound(BlobKey)
    case backend(String)
    /// Digests rather than keys: the scope is shared by construction, and only
    /// the hash can disagree.
    case integrityMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .notFound(let key):
            "no blob at \(key)"
        case .backend(let message):
            "blob storage failed: \(message)"
        case .integrityMismatch(let expected, let actual):
            "blob content hashes to \(actual) but was stored as \(expected)"
        }
    }
}

/// Where large, immutable content lives.
///
/// Split out from FoundationDB because the two halves of storage have opposite
/// shapes: records are small, transactional and indexed; content is large,
/// immutable, and needs none of that. Both backends are first class: a
/// self-hoster runs FoundationDB plus a directory, a cloud deployment runs
/// FoundationDB plus a bucket, and neither is the awkward case.
///
/// Write the blob before the record that points at it, so a record always has
/// bytes behind it; an orphaned blob is a garbage-collection problem, a
/// dangling record is a data-loss one.
public protocol BlobStore: Sendable {
    /// Stores `bytes` at `key`. Idempotent: content addressing guarantees that
    /// writing the same key twice writes the same content.
    func put(_ key: BlobKey, bytes: Data) async throws

    func get(_ key: BlobKey) async throws -> Data?
    func exists(_ key: BlobKey) async throws -> Bool

    /// Removes a blob. Missing is not an error: garbage collection is expected
    /// to race with itself and with concurrent writers.
    func delete(_ key: BlobKey) async throws

    /// Which of `keys` are present. Backends may answer far more cheaply than
    /// one `exists` per key.
    func existing(_ keys: [BlobKey]) async throws -> Set<BlobKey>
}

extension BlobStore {
    public func existing(_ keys: [BlobKey]) async throws -> Set<BlobKey> {
        var present: Set<BlobKey> = []
        for key in keys where try await exists(key) {
            present.insert(key)
        }
        return present
    }

    /// Stores `bytes` after checking they actually hash to `key`.
    ///
    /// The server may not be able to decrypt, but it can verify, and catching
    /// a mismatch on write is far better than discovering it at read time,
    /// when the writer is long gone.
    public func putVerified(_ key: BlobKey, bytes: Data) async throws {
        let actual = SHA256Digest.hex(of: bytes)
        guard actual == key.hex else {
            throw BlobStoreError.integrityMismatch(expected: key.hex, actual: actual)
        }
        try await put(key, bytes: bytes)
    }

    /// Reads a blob that must exist, checking it still hashes to its address.
    public func getVerified(_ key: BlobKey) async throws -> Data {
        guard let bytes = try await get(key) else { throw BlobStoreError.notFound(key) }
        let actual = SHA256Digest.hex(of: bytes)
        guard actual == key.hex else {
            throw BlobStoreError.integrityMismatch(expected: key.hex, actual: actual)
        }
        return bytes
    }

    /// Fetches several blobs at once, with at most `concurrency` requests in
    /// flight.
    ///
    /// Safe to parallelise in a way record reads are not: every backend serves
    /// a blob with an independent request, a `read(2)` or an S3 GET, with no
    /// shared transaction. Bounded so one request cannot exhaust the
    /// connection pool or the file-descriptor budget. Missing blobs are absent
    /// from the result.
    public func getConcurrently(
        _ keys: [BlobKey], concurrency: Int
    ) async throws -> [BlobKey: Data] {
        let unique = Array(Set(keys))
        guard unique.count > 1 else {
            guard let key = unique.first, let bytes = try await get(key) else { return [:] }
            return [key: bytes]
        }

        return try await withThrowingTaskGroup(of: (BlobKey, Data?).self) { group in
            var results: [BlobKey: Data] = [:]
            var next = 0
            let limit = max(1, concurrency)

            while next < unique.count, next < limit {
                let key = unique[next]
                group.addTask { (key, try await self.get(key)) }
                next += 1
            }
            // One completion starts one more, so `limit` requests stay in
            // flight until the queue drains.
            while let (key, bytes) = try await group.next() {
                if let bytes { results[key] = bytes }
                if next < unique.count {
                    let key = unique[next]
                    group.addTask { (key, try await self.get(key)) }
                    next += 1
                }
            }
            return results
        }
    }
}
