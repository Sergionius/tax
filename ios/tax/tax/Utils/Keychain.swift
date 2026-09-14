import Foundation
import Security

protocol KeychainStoring {
    func save(key: String, value: String) throws
    func load(key: String) throws -> String?
    func delete(key: String) throws
}

struct SystemKeychainStore: KeychainStoring {
    func save(key: String, value: String) throws {
        try Keychain.save(key: key, value: value)
    }

    func load(key: String) throws -> String? {
        try Keychain.load(key: key)
    }

    func delete(key: String) throws {
        try Keychain.delete(key: key)
    }
}

enum Keychain {
    static func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.invalidValue }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.operationFailed(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.operationFailed(status)
        }
    }

    static func load(key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.operationFailed(status)
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.operationFailed(status)
        }
    }
}

enum KeychainError: LocalizedError {
    case invalidValue
    case operationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidValue:
            "Could not encode the value for secure storage."
        case let .operationFailed(status):
            "Secure storage is unavailable (OSStatus \(status))."
        }
    }
}
