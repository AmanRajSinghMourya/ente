import 'package:ente_components/ente_components.dart';
import 'package:ente_strings/ente_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:locker/services/update_service.dart';
import 'package:locker/ui/settings/pages/about_page.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets("What's new opens the changelog without a loading state", (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      UpdateService.kChangeLogShownVersionKey: 1,
    });
    final prefs = await SharedPreferences.getInstance();
    await UpdateService.instance.init(
      prefs,
      PackageInfo(
        appName: 'Locker',
        packageName: 'io.ente.locker',
        version: '1',
        buildNumber: '1',
      ),
    );

    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: StringsLocalizations.localizationsDelegates,
        supportedLocales: [Locale('en')],
        home: AboutPage(),
      ),
    );

    final row = find.byWidgetPredicate(
      (widget) => widget is SettingsItem && widget.title == "What's new",
    );
    expect(tester.widget<SettingsItem>(row).showOnlyLoadingState, isFalse);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheetComponent), findsOneWidget);
    expect(
      prefs.getInt(UpdateService.kChangeLogShownVersionKey),
      UpdateService.currentChangeLogVersion,
    );
  });
}
