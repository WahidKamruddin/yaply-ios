import Foundation
import Security

// Low-level Keychain wrappers. KeyStore.swift builds the encryption key API on top of this.
enum KeychainService {
    static let service = "com.yaply.app"

    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
        case unexpectedData
    }

    static func save(key: String, data: Data, accessible: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) throws {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      key,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   accessible,
        ]

        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func load(key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      key,
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data else {
            throw KeychainError.unexpectedData
        }
        return data
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func deleteAll(prefix: String) {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
        ]
        // Enumerate and delete matching items
        var result: AnyObject?
        let fetchQuery: [String: Any] = query.merging([
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]) { $1 }

        if SecItemCopyMatching(fetchQuery as CFDictionary, &result) == errSecSuccess,
           let items = result as? [[String: Any]] {
            for item in items {
                if let account = item[kSecAttrAccount as String] as? String,
                   account.hasPrefix(prefix) {
                    delete(key: account)
                }
            }
        }
    }
}
