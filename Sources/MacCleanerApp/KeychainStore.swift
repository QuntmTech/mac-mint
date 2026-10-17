import Foundation
import Security

/// Stores the account session token and its signed offline evidence in the login Keychain.
enum KeychainStore {
  private static let service = "co.macmint.MacMint.session"
  private static let tokenAccount = "pocketbase-token"
  private static let entitlementAccount = "offline-entitlement"

  static func loadToken() -> String? {
    load(account: tokenAccount).flatMap { String(data: $0, encoding: .utf8) }
  }

  @discardableResult
  static func saveToken(_ token: String) -> Bool { save(Data(token.utf8), account: tokenAccount) }

  static func deleteToken() { delete(account: tokenAccount) }

  static func loadEntitlement() -> Data? { load(account: entitlementAccount) }

  @discardableResult
  static func saveEntitlement(_ data: Data) -> Bool { save(data, account: entitlementAccount) }

  static func deleteEntitlement() { delete(account: entitlementAccount) }

  private static func load(account: String) -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
    return item as? Data
  }

  private static func save(_ data: Data, account: String) -> Bool {
    let match: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let update: [String: Any] = [kSecValueData as String: data]
    let status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
    if status == errSecSuccess { return true }
    guard status == errSecItemNotFound else { return false }
    var add = match
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
  }

  private static func delete(account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
