import Foundation
import Security

private var failDeletion = false
private var failRead = false

// Inject one OS failure while retaining real, signed Keychain operations.
func SecItemDelete(_ query: CFDictionary) -> OSStatus {
  if failDeletion {
    failDeletion = false
    return errSecInteractionNotAllowed
  }
  return Security.SecItemDelete(query)
}

func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
  if failRead {
    failRead = false
    return errSecInteractionNotAllowed
  }
  return Security.SecItemCopyMatching(query, result)
}

enum NotificationKeyStoreChecks {
  static func run() throws {
    let existingItem: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "flutter_secure_storage_service",
      kSecAttrAccount as String: "notification-tests-existing-key"]
    _ = Security.SecItemDelete(existingItem as CFDictionary)
    var attributes = existingItem
    let existingValue = Data("existing account key".utf8)
    attributes[kSecValueData as String] = existingValue
    precondition(SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess)
    defer { _ = Security.SecItemDelete(existingItem as CFDictionary) }
    try NotificationKeyStore.clear()
    let old = try NotificationKeyStore.getOrCreate()
    failDeletion = true
    do {
      try NotificationKeyStore.clear()
      preconditionFailure("The injected deletion must fail")
    } catch NotificationKeyStore.StoreError.keychain(let status) {
      precondition(status == errSecInteractionNotAllowed)
    }
    let afterFailedLogout = try NotificationKeyStore.read()
    guard afterFailedLogout == nil else {
      throw NSError(domain: "NotificationKeyStoreChecks", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Failed logout deletion left the old notification key readable"])
    }
    failDeletion = true
    do {
      _ = try NotificationKeyStore.getOrCreate()
      preconditionFailure("Preparation must wait until the old key is deleted")
    } catch NotificationKeyStore.StoreError.keychain(let status) {
      precondition(status == errSecInteractionNotAllowed)
    }
    let next = try NotificationKeyStore.getOrCreate()
    precondition(next.privateKey != old.privateKey, "The next session must not reuse the old key")
    let reused = try NotificationKeyStore.getOrCreate()
    precondition(reused.privateKey == next.privateKey)
    failRead = true
    do {
      _ = try NotificationKeyStore.getOrCreate()
      preconditionFailure("An inaccessible key must not be replaced")
    } catch NotificationKeyStore.StoreError.keychain(let status) {
      precondition(status == errSecInteractionNotAllowed)
    }
    let afterReadFailure = try NotificationKeyStore.read()
    precondition(afterReadFailure?.privateKey == next.privateKey)
    UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
    let afterInterruptedLogout = try NotificationKeyStore.getOrCreate()
    guard afterInterruptedLogout.privateKey != next.privateKey else {
      throw NSError(domain: "NotificationKeyStoreChecks", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Cleared account preferences must invalidate a surviving notification key"])
    }
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccessGroup as String: NotificationKeyStore.accessGroup,
      kSecAttrService as String: NotificationKeyStore.service,
      kSecAttrAccount as String: NotificationKeyStore.account]
    for data in [Data("invalid JSON".utf8),
      try JSONEncoder().encode(NotificationRecipient(schemaVersion: 1, privateKey: "short"))] {
      precondition(SecItemUpdate(query as CFDictionary,
        [kSecValueData as String: data] as CFDictionary) == errSecSuccess)
      let repaired = try NotificationKeyStore.getOrCreate()
      precondition(repaired.isValid && repaired.privateKey != next.privateKey)
      let reused = try NotificationKeyStore.getOrCreate()
      precondition(reused.privateKey == repaired.privateKey)
    }
    let future = try JSONEncoder().encode(NotificationRecipient(schemaVersion: 2, privateKey: next.privateKey))
    precondition(SecItemUpdate(query as CFDictionary,
      [kSecValueData as String: future] as CFDictionary) == errSecSuccess)
    do {
      _ = try NotificationKeyStore.getOrCreate()
      preconditionFailure("Unsupported record versions must not rotate the key")
    } catch NotificationKeyStore.StoreError.unsupportedVersion {}
    try NotificationKeyStore.clear()
    var existingRead = existingItem
    existingRead[kSecReturnData as String] = true
    var result: CFTypeRef?
    precondition(Security.SecItemCopyMatching(existingRead as CFDictionary, &result) == errSecSuccess)
    precondition(result as? Data == existingValue, "Notification cleanup must preserve existing secure storage")
  }
}
