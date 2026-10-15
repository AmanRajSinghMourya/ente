import 'dart:convert';
import 'dart:io';

import 'package:ente_crypto/ente_crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_sodium/flutter_sodium.dart';
import 'package:logging/logging.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/service_locator.dart';

class NotificationKeyService {
  static const channel = MethodChannel('io.ente.frame.notifications');
  static final _logger = Logger('NotificationKeyService');
  static const _storage = FlutterSecureStorage();
  static const _storageKey = 'notification_recipient';

  static Future<Map<String, Object>?> generateNotificationKey() async {
    if (!flagService.internalUser) return null;
    final sessionToken = Platform.isIOS
        ? Configuration.instance.getToken()
        : null;
    var pair = await getNotificationKeyPair(sessionToken: sessionToken);
    if (pair == null) {
      CryptoUtil.init();
      pair = await CryptoUtil.generateKeyPair();
      await setNotificationKeyPair(pair, sessionToken: sessionToken);
    }
    return {'version': 1, 'publicKey': base64Encode(pair.pk)};
  }

  static Future<KeyPair?> getNotificationKeyPair({String? sessionToken}) async {
    if (Platform.isIOS) {
      final record = await channel.invokeMapMethod<String, String>(
        'getKeyPair',
        {'sessionToken': sessionToken ?? Configuration.instance.getToken()},
      );
      if (record == null) return null;
      return KeyPair(
        pk: base64Decode(record['publicKey']!),
        sk: base64Decode(record['privateKey']!),
      );
    }
    final encoded = await _storage.read(key: _storageKey);
    if (encoded == null) return null;
    final record = jsonDecode(encoded) as Map<String, dynamic>;
    return KeyPair(
      pk: base64Decode(record['publicKey'] as String),
      sk: base64Decode(record['privateKey'] as String),
    );
  }

  static Future<void> setNotificationKeyPair(
    KeyPair? pair, {
    String? sessionToken,
  }) async {
    if (Platform.isIOS) {
      if (pair == null) {
        await channel.invokeMethod<void>('clear');
      } else {
        await channel.invokeMethod<void>('setKeyPair', {
          'sessionToken': sessionToken ?? Configuration.instance.getToken(),
          'privateKey': base64Encode(pair.sk),
        });
      }
      return;
    }
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

  static Future<void> clear() => setNotificationKeyPair(null);

  static Future<void> syncPreference() async {
    try {
      await channel.invokeMethod<void>('syncPreference');
    } catch (e, s) {
      _logger.warning('Could not share notification preference', e, s);
    }
  }
}
