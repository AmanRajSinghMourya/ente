import 'dart:convert';
import 'dart:io';

import 'package:ente_crypto/ente_crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_sodium/flutter_sodium.dart';

class NotificationKeyService {
  static const _storage = FlutterSecureStorage();
  static const _storageKey = 'notification_recipient';

  static Future<Map<String, Object>?> generateNotificationKey() async {
    if (!Platform.isAndroid) return null;
    var pair = await getNotificationKeyPair();
    if (pair == null) {
      CryptoUtil.init();
      pair = await CryptoUtil.generateKeyPair();
      await setNotificationKeyPair(pair);
    }
    return {'version': 1, 'publicKey': base64Encode(pair.pk)};
  }

  static Future<Map<String, dynamic>?> decrypt(
    Map<String, dynamic> data,
  ) async {
    if (data['notificationVersion'] != '1') return null;
    final pair = await getNotificationKeyPair();
    if (pair == null) return null;
    CryptoUtil.init();
    final plaintext = CryptoUtil.openSealSync(
      base64Decode(data['notificationCiphertext'] as String),
      pair.pk,
      pair.sk,
    );
    final event = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
    if (event['version'] != 1 || event['eventType'] is! String) return null;
    return event;
  }

  static Future<KeyPair?> getNotificationKeyPair() async {
    final encoded = await _storage.read(key: _storageKey);
    if (encoded == null) return null;
    final record = jsonDecode(encoded) as Map<String, dynamic>;
    return KeyPair(
      pk: base64Decode(record['publicKey'] as String),
      sk: base64Decode(record['privateKey'] as String),
    );
  }

  static Future<void> setNotificationKeyPair(KeyPair? pair) async {
    if (pair == null) {
      await _storage.delete(key: _storageKey);
    } else {
      await _storage.write(
        key: _storageKey,
        value: jsonEncode({
          'publicKey': base64Encode(pair.pk),
          'privateKey': base64Encode(pair.sk),
        }),
      );
    }
  }
}
