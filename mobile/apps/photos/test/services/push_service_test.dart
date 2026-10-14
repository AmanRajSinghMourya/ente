import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos/services/push_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final shown = <Map<dynamic, dynamic>>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({});
    shown.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'show') shown.add(call.arguments as Map);
          return true;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'referral action shows local copy without message ID or account prefs',
    () async {
      await handleAndroidBackgroundPush(
        const RemoteMessage(data: {'action': 'referral'}),
      );
      expect(shown, hasLength(1));
      expect(shown.single['title'], 'Congratulations! 🎉');
      expect(shown.single['body'], 'You earned a 10 GB referral bonus!');
      expect(shown.single['payload'], 'ente://referral');
    },
  );

  test(
    'unknown actions do not notify and sync keeps its existing route',
    () async {
      await handleAndroidBackgroundPush(
        const RemoteMessage(data: {'action': 'other'}),
      );
      expect(shown, isEmpty);
      expect(
        PushService.shouldSync(const RemoteMessage(data: {'action': 'sync'})),
        isTrue,
      );
      expect(
        PushService.shouldSync(
          const RemoteMessage(data: {'action': 'referral'}),
        ),
        isFalse,
      );
    },
  );
}
