import Foundation
import Security
import LocalAuthentication

public enum Keychain {
    public static func password(for user: String) throws -> String? {
        let query = lookupQuery(user)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound || status == errSecInteractionNotAllowed { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw StorageError.sqlite("Keychain access failed (\(status)).")
        }
        return String(data: data, encoding: .utf8)
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
        let query = base(user)
        let attributes = [kSecValueData as String: Data(password.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            // An item written by a differently signed build can't be updated; replace it instead.
            _ = SecItemDelete(query as CFDictionary); status = errSecItemNotFound
        }
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(password.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StorageError.sqlite("Could not save password in Keychain (\(status)).") }
    }
    public static func delete(for user: String) throws {
        let status = SecItemDelete(base(user) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError.sqlite("Could not remove the saved password (\(status)).") }
    }
    private static func base(_ user: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "tn.ashref.arpeggio.soulseek", kSecAttrAccount as String: user]
    }
}
