import 'dart:io';

import 'package:ente_components/ente_components.dart';
import 'package:ente_strings/ente_strings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_widget/home_widget.dart';
import 'package:integration_test/integration_test.dart';
import 'package:photos/app_mode.dart';
import 'package:photos/ente_theme_data.dart';
import 'package:photos/service_locator.dart';
import 'package:photos/services/notification_key_service.dart';
import 'package:photos/services/notification_service.dart';
import 'package:photos/settings/local_settings.dart';
import 'package:photos/ui/settings/notification_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
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
    expect(
      preferences.getString('token'),
      isNull,
      reason: 'Run cleanup on a signed-out test installation',
    );
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
      await HomeWidget.saveWidgetData<bool>('$account.$key', false);
    }
    service.init(preferences);
    await binding.defaultBinaryMessenger.platformMessagesFinished;
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
    await binding.defaultBinaryMessenger.platformMessagesFinished;
  });

  testWidgets(
    'iOS initialization mirrors defaults and saved preferences; cleanup clears copies',
    (tester) async {
      expect(await read(sharedKey), isTrue);
      expect(await read(socialKey), isTrue);

      await preferences.setBool(socialKey, false);
      service.init(preferences);
      await binding.defaultBinaryMessenger.platformMessagesFinished;
      expect(await read(socialKey), isFalse);

      await NotificationKeyService.setNotificationPrivateKey(null);
      expect(await read(sharedKey), isNull);
      expect(await read(socialKey), isNull);
      expect(preferences.getBool(socialKey), isFalse);
    },
    skip: !Platform.isIOS,
  );

  testWidgets(
    'iOS settings toggles update extension preferences independently',
    (tester) async {
      final originalMode = localSettings.appMode;
      final hadSavedMode = localSettings.isAppModeSet;
      addTearDown(() async {
        await localSettings.setAppMode(originalMode);
        if (!hadSavedMode) await preferences.remove('ls.app_mode');
      });
      await localSettings.setAppMode(AppMode.enteGallery);
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
      await binding.defaultBinaryMessenger.platformMessagesFinished;
      await tester.pumpAndSettle();
      final strings = tester
          .element(find.byType(NotificationSettingsScreen))
          .strings;
      Future<void> toggle(String label) async {
        await tester.tap(
          find.descendant(
            of: find.widgetWithText(SettingsItem, label),
            matching: find.byType(ToggleSwitchComponent),
          ),
        );
        await tester.pumpAndSettle();
        await binding.defaultBinaryMessenger.platformMessagesFinished;
      }

      await toggle(strings.sharedPhotoNotifications);
      expect(await read(sharedKey), isFalse);
      expect(await read(socialKey), isTrue);
      await toggle(strings.socialNotifications);
      expect(await read(sharedKey), isFalse);
      expect(await read(socialKey), isFalse);
      await toggle(strings.sharedPhotoNotifications);
      expect(await read(sharedKey), isTrue);
      expect(await read(socialKey), isFalse);
    },
    skip: !Platform.isIOS,
  );
}
