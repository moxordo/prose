import Foundation
import Security

/// Minimal wrapper over the login Keychain for a single generic-password secret.
/// Used to store the Ollama Cloud API key out of plaintext config files.
public enum Keychain {
    public static let apiKeyService = "prose-ollama-api-key"

    public static func read(service: String = apiKeyService) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    public static func write(_ value: String, service: String = apiKeyService, account: String = NSUserName()) -> Bool {
        let data = Data(value.utf8)
        // Delete any existing item, then add fresh (upsert).
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecAttrAccount as String] = account
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
