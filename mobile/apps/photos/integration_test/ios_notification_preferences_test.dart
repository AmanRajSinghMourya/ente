import 'dart:io';

import 'package:ente_components/ente_components.dart';
import 'package:ente_strings/ente_strings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_widget/home_widget.dart';
import 'package:integration_test/integration_test.dart';
import 'package:photos/ente_theme_data.dart';
import 'package:photos/service_locator.dart';
import 'package:photos/services/notification_key_service.dart';
import 'package:photos/services/notification_service.dart';
import 'package:photos/settings/local_settings.dart';
import 'package:photos/ui/settings/notification_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const sharedKey =
      NotificationService.keyShouldShowNotificationsForSharedPhotos;
  const socialKey = NotificationService.keyShouldShowSocialNotifications;
  const account = kDebugMode ? 'recipient.debug' : 'recipient';
  final service = NotificationService.instance;
  late SharedPreferences preferences;
  final originalValues = <String, bool?>{};
  Future<bool?> read(String key) =>
      HomeWidget.getWidgetData<bool>('$account.$key');

  setUpAll(() async {
    preferences = await SharedPreferences.getInstance();
    await HomeWidget.setAppGroupId(
      'group.io.ente.frame.NotificationServiceExtension',
    );
    ServiceLocator.instance.prefs = preferences;
    ServiceLocator.instance.localSettings = LocalSettings(preferences);
  });

  setUp(() async {
    for (final key in [sharedKey, socialKey]) {
      originalValues[key] = preferences.getBool(key);
      await preferences.remove(key);
    }
    service.init(preferences);
  });

  tearDown(() async {
    for (final entry in originalValues.entries) {
      if (entry.value == null) {
        await preferences.remove(entry.key);
      } else {
        await preferences.setBool(entry.key, entry.value!);
      }
    }
    service.init(preferences);
  });

  testWidgets(
    'iOS shared preferences follow initialization, setters and cleanup',
    (tester) async {
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(await read(sharedKey), isTrue);
      expect(await read(socialKey), isTrue);

      await service.setShouldShowNotificationsForSharedPhotosAndAlbums(false);
      expect(await read(sharedKey), isFalse);
      expect(await read(socialKey), isTrue);
      await service.setShouldShowSocialNotifications(false);
      expect(await read(sharedKey), isFalse);
      expect(await read(socialKey), isFalse);
      await service.setShouldShowNotificationsForSharedPhotosAndAlbums(true);
      expect(await read(sharedKey), isTrue);
      expect(await read(socialKey), isFalse);

      // Initialization repairs stale copies from the app's saved values.
      await HomeWidget.saveWidgetData<bool>('$account.$socialKey', true);
      service.init(preferences);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(await read(socialKey), isFalse);

      // The native cleanup used by logout must only touch this build's two copies.
      expect(
        preferences.getString('token'),
        isNull,
        reason: 'Run cleanup on a signed-out test installation',
      );
      const otherAccount = kDebugMode ? 'recipient' : 'recipient.debug';
      const otherKey = '$otherAccount.$sharedKey';
      final originalOther = await HomeWidget.getWidgetData<bool>(otherKey);
      await NotificationKeyService.setNotificationPrivateKey(null);
      expect(await read(sharedKey), isNull);
      expect(await read(socialKey), isNull);
      expect(await HomeWidget.getWidgetData<bool>(otherKey), originalOther);
      expect(preferences.getBool(sharedKey), isTrue);
      expect(preferences.getBool(socialKey), isFalse);
    },
    skip: !Platform.isIOS,
  );

  testWidgets(
    'iOS settings toggles update extension preferences independently',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();
      await service.initializeForBackground();
      final granted = await FlutterLocalNotificationsPlugin()
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()!
          .requestPermissions(alert: true, badge: true, sound: true);
      expect(granted, isTrue, reason: 'Allow notifications on the test device');
      await tester.pumpWidget(
        MaterialApp(
          theme: lightThemeData,
          localizationsDelegates: StringsLocalizations.localizationsDelegates,
          supportedLocales: StringsLocalizations.supportedLocales,
          home: const NotificationSettingsScreen(),
        ),
      );
      await tester.pumpAndSettle();
      final switches = find.byType(ToggleSwitchComponent);
      expect(switches, findsNWidgets(4));
      await tester.tap(switches.at(0));
      await tester.pumpAndSettle();
      expect(await read(sharedKey), isFalse);
      expect(await read(socialKey), isTrue);
      await tester.tap(switches.at(1));
      await tester.pumpAndSettle();
      expect(await read(sharedKey), isFalse);
      expect(await read(socialKey), isFalse);
      await tester.tap(switches.at(0));
      await tester.pumpAndSettle();
      expect(await read(sharedKey), isTrue);
      expect(await read(socialKey), isFalse);
    },
    skip: !Platform.isIOS,
  );
}
