import 'package:dio/dio.dart';
import 'package:ente_components/ente_components.dart';
import 'package:ente_strings/ente_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/db/ml/base.dart';
import 'package:photos/ente_theme_data.dart';
import 'package:photos/models/collection/collection.dart';
import 'package:photos/service_locator.dart';
import 'package:photos/services/entity_service.dart';
import 'package:photos/services/machine_learning/face_ml/person/person_service.dart';
import 'package:photos/ui/sharing/widgets/participant_role_row.dart';
import 'package:photos/ui/sharing/widgets/participant_row.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'library_sharing_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({
      Configuration.userIDKey: 1,
      Configuration.emailKey: 'owner@example.com',
    });
    final preferences = await SharedPreferences.getInstance();
    ServiceLocator.instance.init(
      preferences,
      Dio(),
      Dio(),
      Dio(),
      PackageInfo(
        appName: 'Photos',
        packageName: 'photos',
        version: '1',
        buildNumber: '1',
      ),
    );
    try {
      await Configuration.instance.init(preferences);
    } catch (_) {}
    PersonService.init(_FakeEntityService(), _FakeMLDataDB(), preferences);
  });

  testWidgets('participant row highlights while pressed', (tester) async {
    await _pumpRow(tester);
    final surface = find.byKey(const ValueKey('menu-item-surface'));
    final colors = tester.element(surface).componentColors;
    Color? surfaceColor() =>
        (tester.widget<AnimatedContainer>(surface).decoration! as BoxDecoration)
            .color;

    expect(surfaceColor(), colors.fillLight);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('friend@example.com')),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(surfaceColor(), colors.fillDarker);
    expect(find.text('Remove'), findsNothing);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(surfaceColor(), colors.fillLight);
    expect(find.text('Remove'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final target in ['email', 'avatar', 'space', 'icon']) {
    testWidgets('long press on $target opens participant menu', (tester) async {
      await _pumpRow(tester);
      final rect = tester.getRect(find.byType(ParticipantRow));
      final position = switch (target) {
        'email' => tester.getCenter(find.text('friend@example.com')),
        'avatar' => Offset(rect.left + 30, rect.center.dy),
        'space' => Offset(rect.right - 70, rect.center.dy),
        _ => tester.getCenter(_menuButton),
      };
      await tester.longPressAt(position);
      await tester.pumpAndSettle();
      _expectMenu();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('icon tap works and current role closes the menu', (
    tester,
  ) async {
    await _pumpRow(tester);
    await tester.tap(_menuButton);
    await tester.pumpAndSettle();
    _expectMenu();
    await tester.tap(find.text('Viewer'));
    await tester.pumpAndSettle();
    expect(find.text('Remove'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('row tap and scrolling do not open the menu', (tester) async {
    await _pumpRow(tester);
    await tester.tap(find.text('friend@example.com'));
    await tester.pumpAndSettle();
    expect(find.text('Remove'), findsNothing);
    await tester.drag(find.text('friend@example.com'), const Offset(0, -60));
    await tester.pumpAndSettle();
    expect(find.text('Remove'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

final _menuButton = find.byWidgetPredicate(
  (widget) => widget is EntePopupMenuButton,
);

void _expectMenu() {
  expect(find.text('Viewer'), findsOneWidget);
  expect(find.text('Collaborator'), findsOneWidget);
  expect(find.text('Admin'), findsOneWidget);
  expect(find.text('Remove'), findsOneWidget);
}

Future<void> _pumpRow(WidgetTester tester) async {
  final collection = librarySharingTestAlbum(
    1,
    recipientRole: CollectionParticipantRole.viewer,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: darkThemeData,
      localizationsDelegates: StringsLocalizations.localizationsDelegates,
      supportedLocales: StringsLocalizations.supportedLocales,
      home: Scaffold(
        body: ListView(
          children: [
            ParticipantRoleRow(
              collection: collection,
              user: collection.sharees.single,
              currentUserID: 1,
              onCollectionChanged: () {},
            ),
            const SizedBox(height: 1000),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeEntityService extends Fake implements EntityService {}

class _FakeMLDataDB extends Fake implements IMLDataDB<int> {}
