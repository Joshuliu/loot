//
//  KeychainHelper.swift
//  Loot MessagesExtension
//

import Foundation
import Security

enum KeychainHelper {

    private static let service = "me.plsloot.loot"
    private static let account = "user_id"

    /// In-memory cache so transcript bubble instances skip Keychain I/O.
    private static var cachedUserId: String?

    /// Returns the stable user ID from Keychain, creating one if needed.
    static func getOrCreateUserId() -> String {
        if let cached = cachedUserId { return cached }
        if let existing = read() {
            cachedUserId = existing
            return existing
        }
        let newId = UUID().uuidString
        save(newId)
        cachedUserId = newId
        return newId
    }

    // MARK: - Private

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      account,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecReturnData as String:       kCFBooleanTrue!,
            kSecMatchLimit as String:       kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private static func save(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }

        // Delete any existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      account,
            kSecAttrSynchronizable as String: kCFBooleanTrue!
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      account,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            print("[KeychainHelper] save failed: \(status)")
        }
    }
}
