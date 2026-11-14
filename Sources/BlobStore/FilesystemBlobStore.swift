public import Foundation

/// Content-addressed files under a root directory.
///
/// This is what makes self-hosting mean "FoundationDB plus a directory".
/// Telling someone their NAS needs an object store to write files to a disk is
/// exactly the bolted-on posture to avoid.
public struct FilesystemBlobStore: BlobStore {
    public let root: URL

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func url(for key: BlobKey) -> URL {
        root.appending(path: key.shardedPath)
    }

    public func put(_ key: BlobKey, bytes: Data) async throws {
        let destination = url(for: key)

        // Already present. Content addressing means "same key" is "same bytes",
        // so rewriting would be pure cost.
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // Write to a temporary file and rename into place, so a torn or
            // interrupted write is never visible as a valid blob.
            let temporary = destination.deletingLastPathComponent()
                .appending(path: ".\(key.fileName).\(UUID().uuidString).tmp")
            try bytes.write(to: temporary, options: .atomic)

            do {
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch {
                // Lost a race with a concurrent writer of the same content.
                // Harmless: whatever is there is byte-identical.
                try? FileManager.default.removeItem(at: temporary)
                guard FileManager.default.fileExists(
                    atPath: destination.path(percentEncoded: false)
                ) else {
                    throw error
                }
            }
        } catch let error as BlobStoreError {
            throw error
        } catch {
            throw BlobStoreError.backend("\(error)")
        }
    }

    public func get(_ key: BlobKey) async throws -> Data? {
        let source = url(for: key)
        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
            return nil
        }
        do {
            return try Data(contentsOf: source)
        } catch {
            throw BlobStoreError.backend("\(error)")
        }
    }

    public func exists(_ key: BlobKey) async throws -> Bool {
        FileManager.default.fileExists(atPath: url(for: key).path(percentEncoded: false))
    }

    public func delete(_ key: BlobKey) async throws {
        let target = url(for: key)
        guard FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: target)
        } catch {
            throw BlobStoreError.backend("\(error)")
        }
    }
}
