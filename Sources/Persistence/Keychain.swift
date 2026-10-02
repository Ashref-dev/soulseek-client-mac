import Foundation
import Security

public enum Keychain {
    public static func password(for user: String) throws -> String? {
        var query = base(user)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw StorageError.sqlite("Keychain access failed (\(status)).")
        }
        return String(data: data, encoding: .utf8)
    }
    public static func save(password: String, for user: String) throws {
        let query = base(user)
        let attributes = [kSecValueData as String: Data(password.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(password.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StorageError.sqlite("Could not save password in Keychain (\(status)).") }
    }
    private static func base(_ user: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "tn.ashref.arpeggio.soulseek", kSecAttrAccount as String: user]
    }
}
