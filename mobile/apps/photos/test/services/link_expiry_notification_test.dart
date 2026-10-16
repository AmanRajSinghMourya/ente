import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:photos/db/collections_db.dart';
import 'package:photos/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final shown = <Map<dynamic, dynamic>>[];
  late Directory directory;
  late PathProviderPlatform previousPaths;
  late SharedPreferences preferences;
  var permission = true;
  final future = DateTime.now()
      .add(const Duration(days: 1))
      .microsecondsSinceEpoch;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('expiry_notification_');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'show') {
            shown.add(Map<dynamic, dynamic>.from(call.arguments as Map));
          }
          if (call.method == 'areNotificationsEnabled') return permission;
          if (call.method == 'getNotificationAppLaunchDetails') {
            return {'notificationLaunchedApp': false};
          }
          return true;
        });
    final db = await CollectionsDB.instance.database;
    await db.execute(
      "INSERT INTO collections(collection_id, owner, encrypted_key, name, type, updation_time) "
      "VALUES (41, '{}', 'key', 'Holiday', 'album', 1)",
    );
  });

  setUp(() async {
    shown.clear();
    permission = true;
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    NotificationService.instance.init(preferences);
  });

  tearDownAll(() async {
    await (await CollectionsDB.instance.database).close();
    PathProviderPlatform.instance = previousPaths;
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  test(
    'uses the affected album name and distinct IDs with link settings payloads',
    () async {
      await NotificationService.instance.showLinkExpiryNotification(41, future);
      await NotificationService.instance.showLinkExpiryNotification(42, future);
      expect(shown, hasLength(2));
      expect(shown[0]['body'], 'Your shared link for Holiday expires soon');
      expect(shown[1]['body'], 'Your shared link expires soon');
      expect(shown[0]['id'], isNot(shown[1]['id']));
      expect(shown[0]['payload'], 'ente://link-settings?collectionID=41');
    },
  );

  test(
    'off suppresses both named and generic expiry notifications; on resumes',
    () async {
      await preferences.setBool(
        NotificationService.keyShouldShowNotificationsForSharedPhotos,
        false,
      );
      await NotificationService.instance.showLinkExpiryNotification(41, future);
      await NotificationService.instance.showLinkExpiryNotification(42, future);
      expect(shown, isEmpty);
      await preferences.setBool(
        NotificationService.keyShouldShowNotificationsForSharedPhotos,
        true,
      );
      await NotificationService.instance.showLinkExpiryNotification(41, future);
      expect(shown, hasLength(1));
    },
  );

  test('does not reveal hidden album names', () async {
    final db = await CollectionsDB.instance.database;
    await db.execute(
      "INSERT INTO collections(collection_id, owner, encrypted_key, name, type, updation_time, mmd_ver, mmd_encoded_json) "
      "VALUES (43, '{}', 'key', 'Private', 'album', 1, 1, '{\"visibility\":2}')",
    );
    await NotificationService.instance.showLinkExpiryNotification(43, future);
    expect(shown.single['body'], 'Your shared link expires soon');
  });

  test('expired deliveries and denied OS permission do not display', () async {
    await NotificationService.instance.showLinkExpiryNotification(41, 1);
    permission = false;
    await NotificationService.instance.showLinkExpiryNotification(41, future);
    expect(shown, isEmpty);
  });
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}
