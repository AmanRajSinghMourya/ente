import 'dart:async';
import 'dart:io';

import 'package:ente_configuration/base_configuration.dart';
import 'package:ente_events/event_bus.dart';
import 'package:ente_events/models/signed_out_event.dart';
import 'package:ente_lock_screen/lock_screen_settings.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:locker/services/configuration.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const secureStorage = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  final config = Configuration.instance;
  final lock = LockScreenSettings.instance;
  late Directory root;
  late SharedPreferences preferences;
  late Map<String, String> storage;
  Completer<void>? deletion;
  late Completer<void> deletionStarted;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('locker_lock_logout_');
    SharedPreferences.setMockInitialValues({
      BaseConfiguration.tokenKey: 'token',
      LockScreenSettings.keyAppLockSet: true,
      LockScreenSettings.keyShouldShowLockScreen: true,
    });
    preferences = await SharedPreferences.getInstance();
    storage = {
      BaseConfiguration.keyKey: 'account-key',
      BaseConfiguration.secretKeyKey: 'account-secret',
      LockScreenSettings.pin: 'pin-hash',
      LockScreenSettings.saltKey: 'salt',
    };
    deletion = null;
    deletionStarted = Completer<void>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    messenger.setMockMethodCallHandler(secureStorage, (call) async {
      final key = call.arguments['key'] as String;
      switch (call.method) {
        case 'read':
          return storage[key];
        case 'containsKey':
          return storage.containsKey(key);
        case 'delete':
          if (key == LockScreenSettings.saltKey && deletion != null) {
            if (!deletionStarted.isCompleted) deletionStarted.complete();
            await deletion!.future;
          }
          storage.remove(key);
          return null;
        default:
          throw StateError('Unexpected storage operation: ${call.method}');
      }
    });
  });

  tearDown(() async {
    if (deletion != null && !deletion!.isCompleted) deletion!.complete();
    await config.logout();
    await Future<void>.delayed(Duration.zero);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(secureStorage, null);
    await root.delete(recursive: true);
  });

  // This must run before lock.init: configuration can log out during startup.
  test('startup auto logout clears lock before lock settings init', () async {
    storage.remove(BaseConfiguration.keyKey);

    await config.init([]);

    expect(config.isLoggedIn(), false);
    expect(storage.containsKey(LockScreenSettings.pin), false);
    expect(storage.containsKey(LockScreenSettings.saltKey), false);
    expect(preferences.getBool(LockScreenSettings.keyAppLockSet), isNull);
  });

  for (final credential in [
    LockScreenSettings.pin,
    LockScreenSettings.password,
  ]) {
    test(
      'signed-out startup clears retained $credential and lock flags',
      () async {
        await preferences.remove(BaseConfiguration.tokenKey);
        await preferences.setBool(
          LockScreenSettings.keyHasMigratedLockScreenChanges,
          true,
        );
        await preferences.setInt(LockScreenSettings.keyInvalidAttempts, 7);
        await preferences.setInt(
          LockScreenSettings.lastInvalidAttemptTime,
          DateTime.now().millisecondsSinceEpoch + 120000,
        );
        storage.remove(LockScreenSettings.pin);
        storage[credential] = 'retained-hash';

        await config.init([]);

        // Assert before lock.init so platform-specific keychain cleanup cannot
        // conceal an omission in configuration startup.
        expect(storage.containsKey(credential), false);
        expect(storage.containsKey(LockScreenSettings.saltKey), false);
        expect(preferences.getBool(LockScreenSettings.keyAppLockSet), isNull);
        expect(
          preferences.getBool(LockScreenSettings.keyShouldShowLockScreen),
          isNull,
        );
        expect(
          preferences.getInt(LockScreenSettings.keyInvalidAttempts),
          isNull,
        );
        expect(
          preferences.getInt(LockScreenSettings.lastInvalidAttemptTime),
          isNull,
        );

        await lock.init(config);
        expect(await lock.shouldShowLockScreen(), false);
        expect(lock.getIsAppLockSet(), false);
      },
    );

    test('logout awaits $credential cleanup and resets app lock', () async {
      storage.remove(LockScreenSettings.pin);
      storage[credential] = 'saved-hash';
      await config.init([]);
      expect(storage[credential], 'saved-hash');
      var signedOut = false;
      final subscription = Bus.instance.on<SignedOutEvent>().listen((_) {
        signedOut = true;
      });
      addTearDown(subscription.cancel);
      await lock.init(config);
      expect(await lock.shouldShowLockScreen(), true);
      expect(lock.getIsAppLockSet(), true);
      deletion = Completer<void>();
      var loggedOut = false;
      final logout = config.logout().then((_) => loggedOut = true);
      await deletionStarted.future;
      await Future<void>.delayed(Duration.zero);
      final returnedBeforeDeletion = loggedOut;
      final signaledBeforeDeletion = signedOut;
      deletion!.complete();
      await logout;

      expect(signaledBeforeDeletion, false);
      expect(returnedBeforeDeletion, false);
      expect(config.isLoggedIn(), false);
      expect(storage.containsKey(BaseConfiguration.keyKey), false);
      expect(storage.containsKey(BaseConfiguration.secretKeyKey), false);
      expect(storage.containsKey(credential), false);
      expect(storage.containsKey(LockScreenSettings.saltKey), false);
      expect(lock.getIsAppLockSet(), false);
      expect(lock.shouldShowSystemLockScreen(), false);

      await config.init([]);
      await lock.init(config);
      expect(await lock.shouldShowLockScreen(), false);
      expect(lock.getIsAppLockSet(), false);

      await preferences.setString(BaseConfiguration.tokenKey, 'new-token');
      storage[BaseConfiguration.keyKey] = 'new-account-key';
      await config.init([]);
      await lock.init(config);
      expect(config.isLoggedIn(), true);
      expect(await lock.shouldShowLockScreen(), false);
      expect(lock.getIsAppLockSet(), false);
    });
  }
}
