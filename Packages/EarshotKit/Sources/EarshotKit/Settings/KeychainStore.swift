import Foundation
import Security

public protocol SecretReading: Sendable {
    func read(_ item: KeychainStore.Item) -> String?
}

/// API keys and tokens live here only: never in UserDefaults, files or logs.
public struct KeychainStore: SecretReading {
    public enum Item: String, Sendable {
        case anthropicKey = "anthropic-api-key"
        case webhookToken = "webhook-token"
        /// The API trigger token of a Claude Code routine (spec 12), never a `claude setup-token` token.
        case routineToken = "routine-token"
    }

    public enum KeychainError: Error, Equatable { case status(OSStatus) }

    public let service: String
    let removeItem: @Sendable (CFDictionary) -> OSStatus

    public init(service: String = "com.stephenthorn.earshot") {
        self.init(service: service, removeItem: { SecItemDelete($0) })
    }

    /// Lets the delete path be exercised without touching a real keychain.
    init(service: String, removeItem: @escaping @Sendable (CFDictionary) -> OSStatus) {
        self.service = service
        self.removeItem = removeItem
    }

    public func read(_ item: Item) -> String? {
        var query = base(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// An empty value deletes the item, and a delete that fails throws, so a key never looks cleared while it is still stored.
    public func write(_ value: String, for item: Item) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try delete(item) }
        let data = Data(trimmed.utf8)
        let updated = SecItemUpdate(base(item) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecItemNotFound {
            var add = base(item)
            add[kSecValueData as String] = data
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError.status(added) }
        } else if updated != errSecSuccess {
            throw KeychainError.status(updated)
        }
    }

    /// Deleting an item that isn't there is fine; any other failure (locked keychain, denied access) throws.
    public func delete(_ item: Item) throws {
        let status = removeItem(base(item) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }

    func base(_ item: Item) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: item.rawValue]
    }
}
