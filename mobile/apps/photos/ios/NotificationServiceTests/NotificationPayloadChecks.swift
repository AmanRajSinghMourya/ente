import Foundation

#if !NOTIFICATION_TEST_APP
@main
#endif
struct NotificationPayloadChecks {
  static func main() throws {
    let recipient = try NotificationRecipient.generate()
    let restored = try JSONDecoder().decode(
      NotificationRecipient.self, from: JSONEncoder().encode(recipient))
    precondition(restored.publicKey == recipient.publicKey)
    precondition(restored.privateKey == recipient.privateKey)
    let stored = try JSONSerialization.jsonObject(with: JSONEncoder().encode(recipient)) as! [String: Any]
    precondition(Set(stored.keys) == ["schemaVersion", "privateKey"], "Only schema version and private key belong in the record")
    precondition(stored["publicKey"] == nil && stored["privateKey"] != nil)
    precondition(Data(base64Encoded: recipient.publicKey!)?.count == 32)
    precondition(Data(base64Encoded: recipient.privateKey)?.count == 32)
    let other = try NotificationRecipient.generate()
    precondition(other.publicKey != recipient.publicKey)

    func seal(_ json: String) -> String {
      let input = Array(json.utf8)
      let key = Array(Data(base64Encoded: recipient.publicKey!)!)
      var encrypted = [UInt8](repeating: 0, count: input.count + 48)
      precondition(crypto_box_seal(&encrypted, input, UInt64(input.count), key) == 0)
      return Data(encrypted).base64EncodedString()
    }
    let valid = seal("{\"version\":1,\"eventType\":\"album_shared\"}")
    precondition(NotificationPayload.decrypt(valid, recipient: recipient)?.eventType == "album_shared")
    let unknown = seal("{\"version\":1,\"eventType\":\"future_event\"}")
    precondition(NotificationPayload.decrypt(unknown, recipient: recipient)?.eventType == "future_event")
    precondition(NotificationPayload.decrypt(valid, recipient: other) == nil)
    for json in [
      "{\"version\":2,\"eventType\":\"album_shared\"}",
      "{}", "invalid json",
    ] {
      precondition(NotificationPayload.decrypt(seal(json), recipient: recipient) == nil)
    }
    precondition(NotificationPayload.decrypt("invalid base64", recipient: recipient) == nil)
    precondition(NotificationPayload.decrypt(Data([1, 2]).base64EncodedString(), recipient: recipient) == nil)
    var tampered = Data(base64Encoded: valid)!
    tampered[tampered.count - 1] ^= 1
    precondition(NotificationPayload.decrypt(tampered.base64EncodedString(), recipient: recipient) == nil)
    if CommandLine.arguments.count > 1 {
      let fixture = try JSONSerialization.jsonObject(
        with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
      let recipient = NotificationRecipient(schemaVersion: 1, privateKey: fixture["privateKey"] as! String)
      let message = fixture["message"] as! [String: Any]
      let apns = message["apns"] as! [String: Any]
      let payload = apns["payload"] as! [String: Any]
      precondition(payload["notificationVersion"] as? Int == 1)
      let decoded = NotificationPayload.decrypt(payload["notificationCiphertext"] as! String,
        recipient: recipient)!
      precondition(decoded.eventType == "album_shared")
      print("PASS: actual Museum sender fixture decrypts with the native payload decoder")
    }
    print("PASS: key generation, record round trip, valid payload, minimal record, wrong key, versions, event types and corrupt ciphertext")
  }
}
