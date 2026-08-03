import Foundation
import Security

public enum KeychainError: Error, Equatable {
    case duplicateItem
    case itemNotFound
    case unhandledError(status: Int32)
}

public final class KeychainManager: @unchecked Sendable {
    public static let shared = KeychainManager()
    private let serviceName: String

    public init(serviceName: String = "ai.listener.gemini-api-key") {
        self.serviceName = serviceName
    }

    public func saveApiKey(_ key: String, account: String = "default") throws {
        guard let data = key.data(using: .utf8) else { return }

        // Delete existing item if present
        try? deleteApiKey(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    public func getApiKey(account: String = "default") throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unhandledError(status: status)
        }

        guard let data = dataTypeRef as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw KeychainError.itemNotFound
        }

        return key
    }

    public func deleteApiKey(account: String = "default") throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    public static func maskedKey(_ key: String?) -> String {
        guard let key = key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "未设置 Key"
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 8 {
            return "****"
        }
        let prefix = trimmed.prefix(4)
        let suffix = trimmed.suffix(4)
        return "\(prefix)...\(suffix)"
    }
}
