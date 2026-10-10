import UIKit
import UserNotifications

@main
final class NativeChecksApp: UIResponder, UIApplicationDelegate {
  func application(_ application: UIApplication,
    didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    let result: String
    do {
      try NotificationPayloadChecks.main()
      try NotificationKeyStoreChecks.run()
      let unrelated = UNMutableNotificationContent()
      unrelated.title = "Existing notification"
      unrelated.body = "Original message"
      NotificationService().didReceive(UNNotificationRequest(identifier: "unrelated", content: unrelated, trigger: nil)) {
        precondition($0.title == unrelated.title && $0.body == unrelated.body)
      }
      let recipient = try NotificationKeyStore.getOrCreate()
      NotificationKeyStore.preferences.set(true, forKey: NotificationKeyStore.preferenceKey)
      for event in ["album_shared", "comment_added", "future_event"] {
        let message = Array("{\"version\":1,\"eventType\":\"\(event)\"}".utf8)
        var ciphertext = [UInt8](repeating: 0, count: message.count + 48)
        let publicKey = Array(Data(base64Encoded: recipient.publicKey!)!)
        precondition(crypto_box_seal(&ciphertext, message, UInt64(message.count), publicKey) == 0)
        let content = UNMutableNotificationContent()
        content.userInfo = ["notificationVersion": 1,
          "notificationCiphertext": Data(ciphertext).base64EncodedString()]
        func checkBody(_ expected: String) {
          var delivered = false
          NotificationService().didReceive(UNNotificationRequest(identifier: "test", content: content, trigger: nil)) {
            precondition($0.body == expected)
            delivered = true
          }
          precondition(delivered)
        }
        checkBody(event == "album_shared" ? "Someone shared an album with you" : "New activity")
        NotificationKeyStore.preferences.set(false, forKey: NotificationKeyStore.preferenceKey)
        checkBody("New activity")
        NotificationKeyStore.preferences.set(true, forKey: NotificationKeyStore.preferenceKey)
        content.userInfo["notificationCiphertext"] = "invalid"
        checkBody("New activity")
      }
      try NotificationKeyStore.clear()
      NotificationKeyStore.preferences.removeObject(forKey: NotificationKeyStore.preferenceKey)
      result = "PASS: native payload and Keychain lifecycle checks"
    } catch {
      result = "FAIL: \(error)"
    }
    let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("result.txt")
    try! result.write(to: file, atomically: true, encoding: .utf8)
    return true
  }
}
