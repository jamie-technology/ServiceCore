public import FDBRecordLayer
public import FoundationDB
public import SwiftProtobuf

/// A client's page request, resolved against the server's ceiling.
///
/// Bound every listing here rather than at each call site: an endpoint that
/// forgets is not visibly different from one that remembers until a tenant
/// has enough rows to notice.
public struct PageBounds: Sendable, Hashable {
    public let limit: Int
    public let continuation: FDB.Bytes?

    /// - Parameters:
    ///   - requestedLimit: What the client asked for. Zero or less means it has
    ///     no opinion, which is a request for the server's default, never for
    ///     everything.
    ///   - cursor: The continuation the client got back from the previous page.
    ///     Empty means "start from the beginning", which is how proto3 encodes
    ///     an unset `bytes` field.
    ///   - maximum: The most this endpoint will return in one page.
    public init(requestedLimit: Int, cursor: some Sequence<UInt8>, maximum: Int) {
        precondition(maximum > 0, "a page ceiling must be positive")
        self.limit = requestedLimit <= 0 ? maximum : min(requestedLimit, maximum)
        let bytes = Array(cursor)
        self.continuation = bytes.isEmpty ? nil : bytes
    }

    /// The first page of at most `limit` records.
    public init(limit: Int) {
        precondition(limit > 0, "a page limit must be positive")
        self.limit = limit
        self.continuation = nil
    }
}

/// One page of records and where to resume.
public struct RecordPage<M: SwiftProtobuf.Message & Sendable>: Sendable {
    public let records: [FDBStoredRecord<M>]

    /// Where the next page starts, or `nil` when there are no more records.
    public let continuation: FDB.Bytes?

    public init(records: [FDBStoredRecord<M>], continuation: FDB.Bytes?) {
        self.records = records
        self.continuation = continuation
    }

    /// The records themselves, without their keys and versions.
    public var messages: [M] { records.map(\.record) }

    /// The continuation as a client sees it: empty when exhausted, since proto3
    /// cannot tell an unset `bytes` field from an empty one.
    public var cursor: [UInt8] { continuation ?? [] }
}

extension FDBRecordStore {
    /// Runs one page of `query`, pushing the bound into the scan.
    ///
    /// Ordering is by key: primary key, or index key for an index scan. That
    /// is a real constraint rather than an oversight. A sort forces the record
    /// layer to materialise the whole result set to order it, which is the
    /// cost pagination exists to avoid. Callers that want a different order
    /// sort a page, and accept that it is a page.
    public func page<M: SwiftProtobuf.Message & Sendable>(
        _ query: RecordQuery<M>, bounds: PageBounds
    ) async throws -> RecordPage<M> {
        let page = try await executeQuery(
            query.limited(to: bounds.limit), continuation: bounds.continuation
        )
        return RecordPage(records: page.records, continuation: page.continuation)
    }

    /// Every record matching `query`, refusing to collect more than `maximum`.
    ///
    /// For the places that genuinely need the whole set in memory. The ceiling
    /// turns "this table grew" into an error rather than an outage.
    public func all<M: SwiftProtobuf.Message & Sendable>(
        _ query: RecordQuery<M>, maximum: Int
    ) async throws -> [M] {
        let page = try await executeQuery(query.limited(to: maximum + 1), continuation: nil)
        guard page.records.count <= maximum else {
            throw TooManyRecords(maximum: maximum, recordType: M.protoMessageName)
        }
        return page.records.map(\.record)
    }
}

/// ``FDBRecordStore/all(_:maximum:)`` found more records than it was allowed
/// to collect.
public struct TooManyRecords: Error, Sendable, CustomStringConvertible {
    public let maximum: Int
    public let recordType: String

    public var description: String {
        "more than \(maximum) \(recordType) records; page through them instead of collecting"
    }
}
