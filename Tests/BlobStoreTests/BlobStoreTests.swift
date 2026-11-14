import BlobStore
import Configuration
import Foundation
import Testing

private let digestOfHello = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

@Suite struct BlobKeyTests {
    @Test func validatesEveryComponent() {
        #expect(BlobKey(scope: "scope-1", hex: digestOfHello) != nil)
        #expect(BlobKey(scope: "scope-1", hex: digestOfHello, token: BlobKey.newToken()) != nil)
        #expect(BlobKey(scope: "../etc", hex: digestOfHello) == nil)
        #expect(BlobKey(scope: "", hex: digestOfHello) == nil)
        #expect(BlobKey(scope: "scope", hex: digestOfHello.uppercased()) == nil)
        #expect(BlobKey(scope: "scope", hex: "abc") == nil)
        #expect(BlobKey(scope: "scope", hex: digestOfHello, token: "../../x") == nil)
        #expect(BlobKey(scope: "scöpe", hex: digestOfHello) == nil)
    }

    @Test func tokensAreWellFormedAndDistinct() {
        let first = BlobKey.newToken(), second = BlobKey.newToken()
        #expect(BlobKey.isValidToken(first))
        #expect(first != second)
    }

    @Test func pathsAreSharded() throws {
        let key = try #require(BlobKey(scope: "s", hex: digestOfHello, token: String(repeating: "a", count: 32)))
        #expect(key.shardedPath == "s/2c/f2/\(digestOfHello).\(String(repeating: "a", count: 32))")
        #expect(try #require(BlobKey(scope: "s", hex: digestOfHello)).shardedPath == "s/2c/f2/\(digestOfHello)")
    }
}

@Suite struct FilesystemBlobStoreTests {
    private func withStore(_ body: (FilesystemBlobStore) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "servicecore-blobs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(try FilesystemBlobStore(root: root))
    }

    @Test func roundTrips() async throws {
        try await withStore { store in
            let key = try #require(BlobKey(scope: "s", hex: digestOfHello, token: BlobKey.newToken()))
            #expect(try await store.get(key) == nil)
            try await store.putVerified(key, bytes: Data("hello".utf8))
            try await store.put(key, bytes: Data("hello".utf8)) // idempotent
            #expect(try await store.exists(key))
            #expect(try await store.getVerified(key) == Data("hello".utf8))
            try await store.delete(key)
            try await store.delete(key) // missing is fine
            #expect(try await store.exists(key) == false)
        }
    }

    @Test func rejectsContentThatDoesNotMatchItsAddress() async throws {
        try await withStore { store in
            let key = try #require(BlobKey(scope: "s", hex: digestOfHello))
            await #expect(throws: BlobStoreError.integrityMismatch(
                expected: digestOfHello, actual: SHA256Digest.hex(of: Data("goodbye".utf8))
            )) {
                try await store.putVerified(key, bytes: Data("goodbye".utf8))
            }
            #expect(try await store.exists(key) == false)
        }
    }

    @Test func fetchesConcurrently() async throws {
        try await withStore { store in
            var keys: [BlobKey] = []
            for index in 0..<10 {
                let bytes = Data("blob \(index)".utf8)
                let key = try #require(BlobKey(scope: "s", hex: SHA256Digest.hex(of: bytes)))
                try await store.put(key, bytes: bytes)
                keys.append(key)
            }
            let missing = try #require(BlobKey(scope: "s", hex: digestOfHello))
            let fetched = try await store.getConcurrently(keys + [missing, keys[0]], concurrency: 3)
            #expect(fetched.count == 10)
            #expect(fetched[missing] == nil)
            #expect(try await store.existing(keys + [missing]) == Set(keys))
        }
    }
}

@Suite struct SignatureV4Tests {
    /// The "GET Object" example from the AWS SigV4 documentation for S3.
    @Test func matchesTheAWSReferenceExample() throws {
        let signer = SignatureV4(
            accessKeyID: "AKIAIOSFODNN7EXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            region: "us-east-1",
            service: "s3"
        )
        let headers = signer.sign(
            method: "GET",
            url: try #require(URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")),
            headers: ["host": "examplebucket.s3.amazonaws.com", "range": "bytes=0-9"],
            payload: Data(),
            date: Date(timeIntervalSince1970: 1_369_353_600) // 2013-05-24T00:00:00Z
        )
        #expect(headers["x-amz-date"] == "20130524T000000Z")
        #expect(headers["Authorization"] == "AWS4-HMAC-SHA256 "
            + "Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "
            + "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, "
            + "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }
}

@Suite struct BlobBackendConfigurationTests {
    @Test func defaultsToTheFilesystem() throws {
        let config = ConfigReader(provider: InMemoryProvider(values: [:]))
        #expect(try BlobBackend(config: config) == .filesystem(root: "blobs"))
    }

    @Test func readsS3() throws {
        let config = ConfigReader(provider: InMemoryProvider(values: [
            "storage.blobs.backend": "s3",
            "storage.blobs.s3.endpoint": "https://s3.example.com",
            "storage.blobs.s3.bucket": "b",
            "storage.blobs.s3.access.key.id": "id",
            "storage.blobs.s3.secret.access.key": "secret",
            "storage.blobs.s3.prefix": "prod",
        ]))
        guard case .s3(let s3) = try BlobBackend(config: config) else {
            Issue.record("expected the S3 backend")
            return
        }
        #expect(s3.bucket == "b")
        #expect(s3.region == "us-east-1")
        #expect(s3.usePathStyle)
        #expect(s3.prefix == "prod")
    }

    @Test func rejectsUnknownBackends() {
        let config = ConfigReader(provider: InMemoryProvider(values: ["storage.blobs.backend": "tape"]))
        #expect(throws: BlobConfigurationError.unknownBackend("tape")) {
            try BlobBackend(config: config)
        }
    }
}
