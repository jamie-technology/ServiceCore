import FDBRecordLayer
import Foundation
import FoundationDB
import FoundationDBCore
import RecordStore
import SwiftProtobuf
import Synchronization
import Testing

/// Well-known types stand in for a service's records, so the tests need no
/// protos of their own.
private let schema = RecordMetaData(version: 1) {
    RecordType(Google_Protobuf_StringValue.self, key: 1, primaryKey: \.value)
        .storingVersions()
}

/// Runs against the local FoundationDB cluster, in a shared test tenant and a
/// fresh path per test, which it clears afterwards.
private func withDatabase(_ body: (RecordDatabase) async throws -> Void) async throws {
    let connection = try await FoundationDBConnection.connect(
        FoundationDBConfiguration(tenant: "servicecore-tests"), retryInterval: nil
    )
    let database = RecordDatabase(
        connection: connection, metaData: schema, path: "test-\(UUID().uuidString.prefix(8))"
    )
    do {
        try await body(database)
    } catch {
        try? await database.withStore { try await $0.deleteAllRecords() }
        throw error
    }
    try await database.withStore { try await $0.deleteAllRecords() }
}

@Suite(.serialized) struct RecordDatabaseTests {
    @Test func savesAndLoads() async throws {
        try await withDatabase { database in
            try await database.withStore { store in
                _ = try await store.save(Google_Protobuf_StringValue("a"))
            }
            let loaded = try await database.withStore { store in
                try await store.load(Google_Protobuf_StringValue.self, primaryKey: Tuple(["a"]))
            }
            #expect(loaded?.record.value == "a")
            #expect(loaded?.version != nil)
        }
    }

    @Test func retriesAfterCommitRunsATransactionTwice() async throws {
        try await withDatabase { database in
            let runs = Counter()
            try await RecordDatabase.$retriesAfterCommit.withValue(true) {
                try await database.withStore { store in
                    runs.increment()
                    // The second run sees the first's committed write.
                    let existing = try await store.load(Google_Protobuf_StringValue.self, primaryKey: Tuple(["once"]))
                    #expect((existing != nil) == (runs.value == 2))
                    _ = try await store.save(Google_Protobuf_StringValue("once"))
                }
            }
            #expect(runs.value == 2)
            try await database.withStore { _ in runs.increment() }
            #expect(runs.value == 3)
        }
    }

    @Test func pagesThroughEverything() async throws {
        try await withDatabase { database in
            try await database.withStore { store in
                for index in 0..<7 {
                    _ = try await store.save(Google_Protobuf_StringValue("record-\(index)"))
                }
            }

            var seen: [String] = []
            var cursor: [UInt8] = []
            var pages = 0
            repeat {
                let bounds = PageBounds(requestedLimit: 100, cursor: cursor, maximum: 3)
                #expect(bounds.limit == 3)
                let page = try await database.withStore { store in
                    try await store.page(RecordQuery(Google_Protobuf_StringValue.self), bounds: bounds)
                }
                seen += page.messages.map(\.value)
                cursor = page.cursor
                pages += 1
            } while !cursor.isEmpty && pages < 10

            #expect(seen == (0..<7).map { "record-\($0)" })
            #expect(pages == 3)
        }
    }

    @Test func refusesToCollectTooMuch() async throws {
        try await withDatabase { database in
            try await database.withStore { store in
                for index in 0..<4 {
                    _ = try await store.save(Google_Protobuf_StringValue("r\(index)"))
                }
            }
            await #expect(throws: TooManyRecords.self) {
                try await database.withStore { store in
                    try await store.all(RecordQuery(Google_Protobuf_StringValue.self), maximum: 3)
                }
            }
            let all = try await database.withStore { store in
                try await store.all(RecordQuery(Google_Protobuf_StringValue.self), maximum: 4)
            }
            #expect(all.count == 4)
        }
    }

    @Test func versionsRoundTripThroughClients() async throws {
        try await withDatabase { database in
            // Separate transactions: a version is a versionstamp, unreadable until its write commits.
            _ = try await database.withStore { store in
                try await store.save(Google_Protobuf_StringValue("v"))
            }
            let saved = try await database.withStore { store in
                try await store.load(Google_Protobuf_StringValue.self, primaryKey: Tuple(["v"]))
            }
            let version = try #require(saved?.version)
            let token = version.base64URLEncoded
            #expect(!token.contains("="))
            #expect(FDBRecordVersion(base64URLEncoded: token) == version)
            #expect(FDBRecordVersion(base64URLEncoded: "not a version") == nil)

            // A stale version is a conflict, and the error says so.
            _ = try await database.withStore { store in
                try await store.save(Google_Protobuf_StringValue("v"))
            }
            let error = await #expect(throws: RecordStoreError.self) {
                try await database.withStore { store in
                    try await store.load(
                        Google_Protobuf_StringValue.self, primaryKey: Tuple(["v"]), expecting: version
                    )
                }
            }
            #expect(error?.isConflict == true)
        }
    }
}

@Suite struct PageBoundsTests {
    @Test func appliesTheCeiling() {
        #expect(PageBounds(requestedLimit: 0, cursor: [], maximum: 50).limit == 50)
        #expect(PageBounds(requestedLimit: -1, cursor: [], maximum: 50).limit == 50)
        #expect(PageBounds(requestedLimit: 10, cursor: [], maximum: 50).limit == 10)
        #expect(PageBounds(requestedLimit: 500, cursor: [], maximum: 50).limit == 50)
    }

    @Test func emptyCursorMeansTheStart() {
        #expect(PageBounds(requestedLimit: 1, cursor: Data(), maximum: 5).continuation == nil)
        #expect(PageBounds(requestedLimit: 1, cursor: Data([1, 2]), maximum: 5).continuation == [1, 2])
    }
}

@Suite struct Base64URLTests {
    @Test func roundTrips() {
        for length in 0..<20 {
            let bytes = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 250) }
            let encoded = Base64URL.encode(bytes)
            #expect(!encoded.contains("+") && !encoded.contains("/") && !encoded.contains("="))
            #expect(Base64URL.decode(encoded) == bytes)
        }
        #expect(Base64URL.decode("a") == nil)
        #expect(Base64URL.decode("ab+c") == nil)
    }
}

private final class Counter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
}
