import Foundation
import Security
import LocalAuthentication

public enum Keychain {
    public static func password(for user: String) throws -> String? {
        try password(for: user, operations: .live)
    }
    static func password(for user: String, operations: Operations) throws -> String? {
        let query = lookupQuery(user)
        var result: CFTypeRef?
        let status = operations.copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.access(status) }
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidPassword
        }
        return password
    }
    static func lookupQuery(_ user: String) -> [String: Any] {
        var query = base(user)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query
    }
    public static func save(password: String, for user: String) throws {
        try save(password: password, for: user, operations: .live)
    }
    static func save(password: String, for user: String, operations: Operations) throws {
        let query = base(user)
        let attributes = [kSecValueData as String: Data(password.utf8)]
        var status = operations.update(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(password.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = operations.add(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.access(status) }
    }
    public static func delete(for user: String) throws {
        try delete(for: user, operations: .live)
    }
    static func delete(for user: String, operations: Operations) throws {
        let status = operations.delete(base(user) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError.sqlite("Could not remove the saved password (\(status)).") }
    }
    private static func base(_ user: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "tn.ashref.arpeggio.soulseek", kSecAttrAccount as String: user]
    }
    struct Operations {
        var copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
        var update: (CFDictionary, CFDictionary) -> OSStatus
        var add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
        var delete: (CFDictionary) -> OSStatus
        static var live: Self {
            Self(copyMatching: SecItemCopyMatching, update: SecItemUpdate, add: SecItemAdd, delete: SecItemDelete)
        }
    }
}

public enum KeychainError: Error, LocalizedError, Sendable {
    case access(OSStatus)
    case invalidPassword

    public var errorDescription: String? {
        switch self {
        case .access(let status) where status == errSecInteractionNotAllowed || status == errSecAuthFailed:
            "Keychain could not authorize access to the saved password (\(status)). Unlock your login keychain and allow this signed app in Keychain Access, or open Account and Server and Sign In with Remember password enabled. The existing saved password has not been removed."
        case .access(let status):
            "Keychain access failed (\(status)). Unlock your login keychain, then open Account and Server and Sign In with Remember password enabled."
        case .invalidPassword:
            "The saved Keychain password could not be read. Open Account and Server and Sign In with Remember password enabled."
        }
    }
}
