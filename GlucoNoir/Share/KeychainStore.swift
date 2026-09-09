//
//  KeychainStore.swift
//  GlucoNoir
//
//  Dexcom credentials live here and nowhere else — never UserDefaults, never
//  the diagnostic log.
//

import Foundation
import Security

nonisolated enum KeychainStore {

    private static let service = "com.joshscott.GlucoNoir.dexcomShare"
    private static let account = "shareCredentials"

    /// `AfterFirstUnlock`, not `WhenUnlocked`: the app polls while the phone is
    /// locked, and `WhenUnlocked` would make the item unreadable exactly then —
    /// and unreadable after a reboot until the user unlocks.
    private static let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    struct Stored: Codable {
        var username: String
        var password: String
        var region: String
    }

    static func save(_ credentials: ShareCredentials) throws {
        let stored = Stored(
            username: credentials.username,
            password: credentials.password,
            region: credentials.region.rawValue
        )
        let data = try JSONEncoder().encode(stored)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = accessibility

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Keychain write failed (\(status))"])
        }
    }

    static func load() -> ShareCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return nil
        }
        return ShareCredentials(
            username: stored.username,
            password: stored.password,
            region: ShareRegion(rawValue: stored.region) ?? .us
        )
    }

    @discardableResult
    static func clear() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
