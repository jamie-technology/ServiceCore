import Foundation
import Security

/// The access token in the keychain, shared by an app and its extensions
/// through a keychain access group.
///
/// The keychain has no compare-and-set, so this never updates an item: each
/// token version is a separate generic-password item, its version in the
/// account name. Reading takes the highest; storing adds an item and then
/// deletes lower ones. Two processes storing at once each add their own item,
/// and whichever version is higher wins, in every process, with no locks.
/// (A file lock in the shared container would also work, but iOS kills a
/// suspended process that holds one, and extensions are suspended constantly.)
///
/// After every change it posts a Darwin notification, which
/// ``AccessTokenStorage/changes()`` turns into a stream in every process.
public final class KeychainAccessTokenStorage: AccessTokenStorage {
    public let service: String
    public let accessGroup: String?
    private let accessibility: String
    private let useDataProtectionKeychain: Bool
    private let notification: DarwinNotification

    /// - Parameters:
    ///   - service: The items' `kSecAttrService`, e.g. `"com.example.notes.access-token"`.
    ///   - accessGroup: The keychain access group shared with the extensions,
    ///     e.g. `"<TeamID>.com.example.notes"`. `nil` for the app's default.
    ///   - accessibility: Extensions often run while the device is locked, hence
    ///     the default `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
    ///   - useDataProtectionKeychain: Always on for iOS-family platforms. On
    ///     macOS it needs a signed app with a keychain entitlement; pass `false`
    ///     only for unsigned tools and tests, which use the login keychain.
    ///   - notificationName: The Darwin notification posted on changes;
    ///     defaults to `"<service>.changed"`. Must match across processes.
    public init(
        service: String,
        accessGroup: String? = nil,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        useDataProtectionKeychain: Bool = true,
        notificationName: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.accessibility = accessibility as String
        self.useDataProtectionKeychain = useDataProtectionKeychain
        self.notification = DarwinNotification(name: notificationName ?? "\(service).changed")
    }

    public func current() throws -> StoredAccessToken? {
        // Another process may prune the highest item between listing and
        // reading it, if it has just stored a higher one: then look again.
        for _ in 0..<5 {
            let versions = try storedVersions()
            guard let highest = versions.max() else { return nil }
            if let data = try data(for: highest) {
                pruneQuietly(below: highest, among: versions)
                return StoredAccessToken(accessToken: String(decoding: data, as: UTF8.self), version: highest)
            }
        }
        throw KeychainError(status: errSecItemNotFound)
    }

    public func offer(_ token: StoredAccessToken) throws -> Bool {
        let versions = try storedVersions()
        if let highest = versions.max(), highest >= token.version {
            return highest == token.version
        }
        var item = baseQuery()
        item[kSecAttrAccount] = Self.account(for: token.version)
        item[kSecValueData] = Data(token.accessToken.utf8)
        item[kSecAttrAccessible] = accessibility as CFString
        let status = SecItemAdd(item as CFDictionary, nil)
        // A duplicate is the same version, stored by another process: same token.
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw KeychainError(status: status) }
        pruneQuietly(below: token.version, among: versions)
        notification.post()
        return true
    }

    public func remove(upTo version: AccessTokenVersion) throws {
        for stored in try storedVersions() where stored <= version {
            try delete(stored)
        }
        notification.post()
    }

    public func removeAll() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
        notification.post()
    }

    public func changes() -> AsyncStream<Void> {
        notification.stream()
    }

    // MARK: - Items

    /// Zero-padded so names also sort by version.
    static func account(for version: AccessTokenVersion) -> String {
        "v1." + pad(version.signedInAt) + "." + pad(version.generation)
    }

    static func version(fromAccount account: String) -> AccessTokenVersion? {
        let parts = account.split(separator: ".")
        guard parts.count == 3, parts[0] == "v1", let signedInAt = UInt64(parts[1]), let generation = UInt64(parts[2]) else {
            return nil
        }
        return AccessTokenVersion(signedInAt: signedInAt, generation: generation)
    }

    private static func pad(_ value: UInt64) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, 20 - digits.count)) + digits
    }

    private func baseQuery() -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrSynchronizable: false,
        ]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        if useDataProtectionKeychain { query[kSecUseDataProtectionKeychain] = true }
        return query
    }

    private func storedVersions() throws -> [AccessTokenVersion] {
        // Attributes only: asking for data together with kSecMatchLimitAll is
        // refused by some keychain classes and OS versions.
        var query = baseQuery()
        query[kSecMatchLimit] = kSecMatchLimitAll
        query[kSecReturnAttributes] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        let items = result as? [[CFString: Any]] ?? []
        return items.compactMap { ($0[kSecAttrAccount] as? String).flatMap(Self.version(fromAccount:)) }
    }

    private func data(for version: AccessTokenVersion) throws -> Data? {
        var query = baseQuery()
        query[kSecAttrAccount] = Self.account(for: version)
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data
    }

    private func delete(_ version: AccessTokenVersion) throws {
        var query = baseQuery()
        query[kSecAttrAccount] = Self.account(for: version)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    /// Deleting only lower versions is safe whoever else is pruning.
    private func pruneQuietly(below version: AccessTokenVersion, among versions: [AccessTokenVersion]) {
        for stored in versions where stored < version {
            try? delete(stored)
        }
    }
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "keychain error \(status): \(message)"
    }
}
