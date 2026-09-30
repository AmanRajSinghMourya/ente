import 'dart:async';
import 'package:dio/dio.dart';
import 'package:ente_components/ente_components.dart';
import 'package:ente_strings/ente_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/db/ml/dart_db.dart';
import 'package:photos/ente_theme_data.dart';
import 'package:photos/gateways/entity/entity_gateway.dart';
import 'package:photos/models/api/collection/user.dart';
import 'package:photos/models/collection/collection.dart';
import 'package:photos/services/entity_service.dart';
import 'package:photos/services/machine_learning/face_ml/person/person_service.dart';
import 'package:photos/ui/sharing/choose_access_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    try {
      await Configuration.instance.init(prefs);
    } on MissingPluginException {
      // The sheet only needs Configuration's preferences-backed identity.
    }
    PersonService.init(
      EntityService(prefs, EntityGateway(Dio())),
      DartMLDataDB.instance,
      prefs,
    );
  });
  testWidgets("rapid removal and confirmation excludes the removed recipient", (
    tester,
  ) async {
    final selected = [alice, bob];
    List<String>? submitted;
    await openSheet(
      tester,
      selected,
      onConfirm: () {
        submitted = selected.map((person) => person.email).toList();
      },
    );
    await tester.tap(find.byKey(const ValueKey("remove-alice@example.com")));
    await tester.pump(const Duration(milliseconds: 10));
    await tester.tap(find.byType(ButtonComponent));
    await tester.pump();
    expect(submitted, ["bob@example.com"]);
    await tester.pumpAndSettle();
  });

  testWidgets(
    "last recipient is removed immediately while its chip fades out",
    (tester) async {
      final selected = [alice];
      await openSheet(tester, selected);
      await tester.tap(find.byKey(const ValueKey("remove-alice@example.com")));
      expect(selected, isEmpty);
      await tester.pump();
      expect(
        tester.widget<ButtonComponent>(find.byType(ButtonComponent)).isDisabled,
        isTrue,
      );
      final chip = find.byKey(
        const ValueKey("selected-person-chip-alice@example.com"),
      );
      await tester.pump(const Duration(milliseconds: 90));
      expect(chip, findsOneWidget);
      final opacity = tester.widget<Opacity>(
        find.descendant(of: chip, matching: find.byType(Opacity)),
      );
      expect(opacity.opacity, allOf(greaterThan(0), lessThan(1)));
      expect(
        find.byKey(const ValueKey("remove-alice@example.com")).hitTestable(),
        findsNothing,
      );
      await tester.pumpAndSettle();
      expect(chip, findsNothing);
    },
  );

  testWidgets("dismissing the sheet during removal does not undo the removal", (
    tester,
  ) async {
    final selected = [alice, bob];
    await openSheet(tester, selected);
    await tester.tap(find.byKey(const ValueKey("remove-alice@example.com")));
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(selected.map((person) => person.email), ["bob@example.com"]);
  });

  testWidgets(
    "multiple removals update selection before either animation ends",
    (tester) async {
      final selected = [alice, bob];
      await openSheet(tester, selected);
      await tester.tap(find.byKey(const ValueKey("remove-alice@example.com")));
      await tester.tap(find.byKey(const ValueKey("remove-bob@example.com")));
      expect(selected, isEmpty);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey("selected-person-chip-alice@example.com")),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey("selected-person-chip-bob@example.com")),
        findsNothing,
      );
    },
  );
}

const alice = UserSuggestion("alice@example.com");
const bob = UserSuggestion("bob@example.com");

Future<void> openSheet(
  WidgetTester tester,
  List<UserSuggestion> selected, {
  VoidCallback? onConfirm,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: lightThemeData,
      localizationsDelegates: StringsLocalizations.localizationsDelegates,
      supportedLocales: StringsLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              unawaited(
                showChooseAccessSheet(
                  context,
                  selected: selected,
                  initialRole: CollectionParticipantRole.viewer,
                ).then((role) {
                  if (role != null) onConfirm?.call();
                }),
              );
            },
            child: const Text("Open access"),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text("Open access"));
  await tester.pumpAndSettle();
}
