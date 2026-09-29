import 'dart:io';

import 'package:ente_strings/ente_strings.dart';
import 'package:ente_ui/pages/settings_search_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:locker/ui/settings/search/settings_search_registry.dart';

import '../../test_utils/configuration_test_util.dart';

void main() {
  late Directory testRoot;

  setUp(() async {
    testRoot = await setupLockerConfigurationForTest('settings_search');
  });

  tearDown(() async {
    clearLockerConfigurationTestHandlers();
    await testRoot.delete(recursive: true);
  });

  testWidgets('searching About keeps its other links visible', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: StringsLocalizations.localizationsDelegates,
        supportedLocales: const [Locale('en')],
        home: Builder(
          builder: (context) => SettingsSearchPage(
            items: SettingsSearchRegistry.getSearchableItems(context),
            suggestions: const [],
            onNavigate: (_, _) {},
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'about');
    await tester.pump();

    expect(find.text("What's new"), findsOneWidget);
    expect(find.text('Blog'), findsOneWidget);
  });
}
