import 'dart:io';
import 'dart:typed_data';

import 'package:ente_lock_screen/lock_screen_settings.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos/app_mode.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/services/notification_key_service.dart';
import 'package:photos/settings/local_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    final root = await Directory.systemTemp.createTemp('photos_token_');
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(paths, null);
      await root.delete(recursive: true);
    });
  });

  test('keeps the session while secure storage is unavailable', () async {
    const secureStorage = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    final secureValues = {
      Configuration.tokenKey: 'token',
      Configuration.keyKey: 'a2V5',
    };
    var isAvailable = false;
    final changes = <String>[];
    messenger.setMockMethodCallHandler(secureStorage, (call) async {
      if (call.method != 'read') {
        changes.add(call.method);
        return null;
      }
      if (!isAvailable) {
        throw PlatformException(code: 'unavailable');
      }
      return secureValues[(call.arguments as Map)['key']];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(secureStorage, null));
    SharedPreferences.setMockInitialValues({
      Configuration.hasSecureTokenKey: true,
      Configuration.userIDKey: 1,
    });
    final preferences = await SharedPreferences.getInstance();
    final config = Configuration.instance;

    await config.init(preferences);

    expect(preferences.getBool(Configuration.hasSecureTokenKey), true);

    isAvailable = true;
    await config.init(preferences);

    expect(config.getToken(), 'token');
    expect(changes, isEmpty);
  });

  test('moves a plaintext token into secure storage', () async {
    SharedPreferences.setMockInitialValues({Configuration.tokenKey: 'token'});
    final secureValues = {
      Configuration.keyKey: 'a2V5',
      Configuration.secretKeyKey: 'c2VjcmV0',
    };
    FlutterSecureStorage.setMockInitialValues(secureValues);
    final config = Configuration.instance;

    await config.init(await SharedPreferences.getInstance());

    final preferences = await SharedPreferences.getInstance();
    expect(config.getToken(), 'token');
    expect(secureValues[Configuration.tokenKey], 'token');
    expect(preferences.getString(Configuration.tokenKey), 'token');

    await config.init(preferences);
    expect(preferences.containsKey(Configuration.tokenKey), false);
    expect(config.getToken(), 'token');
    expect(secureValues[Configuration.tokenKey], 'token');
  });

  for (final hasStaleMarker in [false, true]) {
    test(
      hasStaleMarker
          ? 'Local Gallery keeps its PIN if a saved session token is missing'
          : 'Local Gallery keeps its PIN and clears unfinished account setup',
      () async {
        SharedPreferences.setMockInitialValues({
          LockScreenSettings.keyAppLockSet: true,
          if (hasStaleMarker) Configuration.hasSecureTokenKey: true,
        });
        const storage = FlutterSecureStorage();
        FlutterSecureStorage.setMockInitialValues({
          if (!hasStaleMarker) Configuration.tokenKey: 'unfinished-token',
          Configuration.keyKey: 'unfinished-key',
          Configuration.secretKeyKey: 'unfinished-secret-key',
          LockScreenSettings.pin: 'pin-hash',
          LockScreenSettings.saltKey: 'c2FsdA==',
        });
        await NotificationKeyService.setNotificationPrivateKey(Uint8List(32));
        final preferences = await SharedPreferences.getInstance();
        final settings = LocalSettings(preferences);
        await settings.setAppMode(AppMode.localGallery);

        final config = Configuration.instance;
        final lock = LockScreenSettings.instance;
        await config.init(preferences);
        final isLocalGallery = LocalSettings(preferences).isLocalGalleryMode;
        await lock.init(config, hasOptedForOfflineMode: isLocalGallery);

        expect(config.isLoggedIn(), isFalse);
        expect(
          preferences.containsKey(Configuration.hasSecureTokenKey),
          isFalse,
        );
        expect(isLocalGallery, isTrue);
        expect(await lock.shouldShowLockScreen(), isTrue);
        expect(await storage.readAll(), {
          LockScreenSettings.pin: 'pin-hash',
          LockScreenSettings.saltKey: 'c2FsdA==',
        });
      },
    );
  }

  test('startup clears stale credentials when preferences are empty', () async {
    SharedPreferences.setMockInitialValues({});
    const storage = FlutterSecureStorage();
    FlutterSecureStorage.setMockInitialValues({
      Configuration.tokenKey: 'stale-token',
      Configuration.keyKey: 'stale-key',
      Configuration.secretKeyKey: 'stale-secret-key',
      LockScreenSettings.pin: 'stale-pin-hash',
      LockScreenSettings.saltKey: 'c2FsdA==',
    });
    final config = Configuration.instance;

    await config.init(await SharedPreferences.getInstance());

    expect(config.isLoggedIn(), isFalse);
    expect(await storage.readAll(), isEmpty);
  });
}
