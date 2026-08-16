import Foundation
import Security

/// The Capy API key's only storage: one generic-password item (kSecClassGenericPassword) in the user's login
/// Keychain. The key never touches Data/, logs, generated packages, saved transcripts or error messages — code that
/// needs it loads it from here at call time and keeps it out of published state. Every failure is a named OSStatus
/// message, never a silent no-op that leaves the user believing the key was saved.
struct CapyKeyStore: Sendable {
    var service = "AI Mix Assistant"
    var account = "capy-api-key"

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// The stored key, or nil when none exists (or the Keychain refused the read).
    func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces the stored key. Returns nil on success, otherwise a named failure for the UI.
    func save(_ key: String) -> String? {
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { return "The Keychain refused to store the key (\(Self.describe(status)))." }
        return nil
    }

    /// Removes the stored key. Returns nil on success (a key that was already absent counts as removed).
    func remove() -> String? {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { return "The Keychain refused to remove the key (\(Self.describe(status)))." }
        return nil
    }

    private static func describe(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}
