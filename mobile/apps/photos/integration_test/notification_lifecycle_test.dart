import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/service_locator.dart';
import 'package:photos/services/notification_key_service.dart';
import 'package:photos/services/notification_service.dart';
import 'package:photos/services/push_service.dart';
import 'package:photos/src/rust/frb_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();
  final notifications = FlutterLocalNotificationsPlugin();
  late SharedPreferences preferences;

  setUpAll(() async {
    await EntePhotosRust.init();
    expect(
      await notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()!
          .areNotificationsEnabled(),
      isTrue,
      reason: 'Grant Android notification permission before running this test',
    );
  });

  setUp(() async {
    preferences = await SharedPreferences.getInstance();
    await preferences.clear();
    await storage.deleteAll();
    await notifications.cancelAll();
    NotificationService.instance.init(preferences);
  });

  tearDown(() async {
    await preferences.clear();
    await storage.deleteAll();
    await notifications.cancelAll();
  });

  testWidgets('overlapping enrollment reuses one persisted private key', (
    tester,
  ) async {
    final keys = await Future.wait(
      List.generate(8, (_) => NotificationKeyService.generateNotificationKey()),
    );
    expect(keys.toSet().length, 1);
    expect(await NotificationKeyService.generateNotificationKey(), keys.first);
    final stored = await storage.readAll();
    expect(stored.length, 1);
    expect(base64Decode(stored.values.single), hasLength(32));

    await storage.deleteAll();
    expect(
      await NotificationKeyService.generateNotificationKey(),
      isNot(keys.first),
    );
  });

  testWidgets('fallback is shown when signed in and suppressed after logout', (
    tester,
  ) async {
    await preferences.setBool(Configuration.hasSecureTokenKey, true);
    Future<void> receive() =>
        NotificationService.instance.handlePushNotification(
          {'notificationCiphertext': 'invalid'},
          onSync: () async =>
              fail('An undecryptable push must not request sync'),
        );

    await receive();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(await notifications.getActiveNotifications(), hasLength(1));
    await notifications.cancelAll();

    final rootToken = RootIsolateToken.instance!;
    await compute(_clearAccount, rootToken);
    expect(preferences.getBool(Configuration.hasSecureTokenKey), isTrue);
    await receive();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(await notifications.getActiveNotifications(), isEmpty);
  });

  testWidgets('file like pushes request sync without a direct alert', (
    tester,
  ) async {
    // Go HPKE fixture for the all-zero 32-byte test seed.
    const ciphertext =
        'og+lN9bB2JDW68IcuprzME+59mgyAOOIGn9yu5oiZpGxdrKWWq+J4wNBPzWfF1uXC2ylv3uWmhu5ywYJ1novjO4cxuu/ft83j2Li'
        'jVQEqnpfRQvoX3ze8CiIuOIvCgBq32pqHZaGaELDqYb9PHNHx4fnIWo+Ge3DP+MI3788/4RSy0ATp07hQXJCrrriN8ovNZWiUmSa'
        'mBveDcWtNR+Uaibr8GR4gXpc7h/89XSCI3Rj7ZCTA6WhrQjXZOe7rfEeEEnZ15xzM24Y+F9o+dG2G4CxFQX3cyk5jWvf7a9xoAV9'
        'wTBJZOqWHmv4uxKgRJwTNkzcmy3Gn8XlqEWo38Mu3P2tvMfVxRkCh+LYIFAN3pq7CjGj29clnBbx5uRkxM8X4MzvQ392WUSeS9ja'
        '/h9E+PbkIbRHI5kluyNErGP3/gQ5q/xLv7TAlJTZVTbVQxrIW5wqeqmNfhSPjxHXD3lAsK/LUpgrqZGZ3WjRSvkoNugnEj2JYCeC'
        '9afIQGD4fy6KAcmbWqWbzQmivyZz5UAtZqfL79coOEMPdXIjh09DQGaNO7dzGC7AHIyTZ66/9vopLzQL4zIm06kh2g8JDn54a0DJ'
        'ElNmDRwm8LUxc7CD6pmcZHo1bZspzGzgCjUj6LYrOFGpZyTRj9iKhnl7kME6P/r3dXFhxk4Y4SNJwfsmB5NBo5hYO3tvbmE3zzh2'
        'asfVRTLm3K7jg4ehHlcixPSLICGRYuifMUzULpWdVKPmo/ZToWDG0Kei/wx5MPO4/RNbVQX+AjOiwlxX8gjFANZWgTqR21LjTDUo'
        'Tg5Tdi4TkeJ36+RDY+hpDWOMT256EdhwuqjuyWTYTH0Vq0subpLl5UnueeSMpNSx0QY30icGbZ1zIW187uw6vwthuH7G1aOm3EbT'
        '9MJy/LiFDKtoLzs0i3DkCZ25Sm3NkSfahVR6IATOPCJiL6G76gXJzJcr3Ij9bXnUZf0xUzCAVd8fC77CmTqRe15JPKu5nximcDtr'
        'bKGbIQGJv6MMByRBbzO4U0aW2n16NJiGro8YngjoH0tKoxt8en88aJQb0/oJo676LsYt9V1NzbdKmEbfbTvLoC1ddd+/yYus1nEr'
        'Qv9YqPds+TwQhVIR9wGibqhLI5tRAY1qF3XFKawStAplUzUzZxM6wPKt3VFcwLzOJIWNPhfgbjn+4zVpy4KLW9g67S3B5HYIn10N'
        'PCOq/WUA/Vs4qGdaRZCUmOPFcn9PTgResAWBjVQJlhx9e/QvWthDrC6/U4nOagjhD8CcRvGzhBwC8KLH8DXTxTjEHuxFJzHxz4aw'
        'dtKJeBnlBYeqhn/KB/EHvk2Tx7QUuTCDO3RSom7ly67kWUH9Xz4EbRafNuZJeWY44MV7I5kxMuMMSVM0BlOsM1oiijKGbxdqqLuF'
        'wrP2yNIOwyXgQJxbQUlRyqnw77cPaDwReeV8NCZU3kBJ70yiw4h6sDCocndfwRsHZf0QxRv3PWFLX8XT199wiXHJHvSUURu8fRMx'
        'Viozz5X27YGb3steqr5XNe9GPQxo323EwOKJxNvv7bIj86SegA==';
    await NotificationKeyService.setNotificationPrivateKey(Uint8List(32));
    await preferences.setString(Configuration.tokenKey, 'test-session');
    var syncs = 0;
    for (var delivery = 0; delivery < 2; delivery++) {
      await NotificationService.instance.handlePushNotification({
        'notificationCiphertext': ciphertext,
      }, onSync: () async => syncs++);
    }
    expect(syncs, 2);
    expect(await notifications.getActiveNotifications(), isEmpty);
  });

  testWidgets('failed key preparation can be retried after clearing storage', (
    tester,
  ) async {
    await NotificationKeyService.setNotificationPrivateKey(Uint8List(1));
    await expectLater(
      NotificationKeyService.generateNotificationKey(),
      throwsA(anything),
    );
    await storage.deleteAll();
    final publicKey = await NotificationKeyService.generateNotificationKey();
    expect(publicKey, isNotNull);
  });

  testWidgets('ordinary Android registration enrolls a key on normal refresh', (
    tester,
  ) async {
    final registrations = <Map<String, dynamic>>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/push/token') {
              registrations.add(Map<String, dynamic>.from(options.data as Map));
            }
            handler.resolve(Response(requestOptions: options, data: {}));
          },
        ),
      );
    ServiceLocator.instance.prefs = preferences;
    ServiceLocator.instance.enteDio = dio;
    await preferences.setString(Configuration.tokenKey, 'test-session');
    await storage.write(key: Configuration.keyKey, value: 'a2V5');
    await Configuration.instance.init(preferences);
    await preferences.setBool('ls.internal_user_disabled', true);
    await preferences.setString('remote_flags', '{"internalUser":false}');
    expect(flagService.internalUser, isFalse);

    await PushService.instance.init();
    expect(registrations, hasLength(1));
    final publicKey = registrations.single['notificationKey'] as String;
    expect(base64Decode(publicKey), hasLength(1216));
    expect(registrations.single['platform'], 'android');
    expect(publicKey, await NotificationKeyService.generateNotificationKey());

    await PushService.instance.init();
    expect(registrations, hasLength(1), reason: 'Keep the existing cadence');
    await preferences.setInt(PushService.kLastFCMTokenUpdationTime, 0);
    await PushService.instance.init();
    expect(registrations, hasLength(2));
    expect(registrations.last['notificationKey'], publicKey);

    await NotificationKeyService.setNotificationPrivateKey(Uint8List(1));
    await preferences.setInt(PushService.kLastFCMTokenUpdationTime, 0);
    await PushService.instance.init();
    expect(registrations, hasLength(3));
    expect(registrations.last['notificationKey'], isNull);
    expect(registrations.last['fcmToken'], registrations.first['fcmToken']);
  });
}

Future<void> _clearAccount(RootIsolateToken rootToken) async {
  BackgroundIsolateBinaryMessenger.ensureInitialized(rootToken);
  await (await SharedPreferences.getInstance()).clear();
  await const FlutterSecureStorage().deleteAll();
}
