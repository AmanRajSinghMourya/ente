import 'dart:io';

import 'package:ente_components/ente_components.dart';
import 'package:ente_sharing/models/user.dart';
import 'package:ente_strings/ente_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:locker/services/collections/models/collection.dart';
import 'package:locker/services/configuration.dart';
import 'package:locker/ui/components/collection_selection_widget.dart';
import 'package:locker/ui/pages/account_credentials_page.dart';
import 'package:locker/ui/pages/base_info_page.dart';
import 'package:locker/ui/pages/personal_note_page.dart';
import 'package:locker/ui/pages/physical_records_page.dart';
import 'package:locker/ui/pages/save_page.dart';

import '../../test_utils/configuration_test_util.dart';

void main() {
  late Directory testRoot;
  final collection = Collection(
    42,
    User(id: 1, email: 'owner@example.com'),
    '',
    null,
    'Documents',
    null,
    null,
    CollectionType.folder,
    CollectionAttributes(),
    const [],
    const [],
    0,
  );

  setUp(() async {
    testRoot = await setupLockerConfigurationForTest('fixed_collection_save');
    await Configuration.instance.setUserID(1);
  });

  tearDown(() async {
    clearLockerConfigurationTestHandlers();
    await testRoot.delete(recursive: true);
  });

  final forms = [
    (
      label: 'Note',
      page: () => PersonalNotePage(fixedCollection: collection),
      requiredField: 1,
    ),
    (
      label: 'Thing',
      page: () => PhysicalRecordsPage(fixedCollection: collection),
      requiredField: 0,
    ),
    (
      label: 'Secret',
      page: () => AccountCredentialsPage(fixedCollection: collection),
      requiredField: 0,
    ),
  ];

  for (final form in forms) {
    testWidgets('${form.label} is ready to save without loading a picker', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: StringsLocalizations.localizationsDelegates,
          supportedLocales: const [Locale('en')],
          home: form.page(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextField).at(form.requiredField),
        'Test',
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Documents'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.byType(CollectionSelectionWidget), findsNothing);
      expect(find.text('Documents'), findsOneWidget);
      final save = tester.widget<ButtonComponent>(
        find.byType(ButtonComponent).last,
      );
      expect(save.onTap, isNotNull);
    });

    testWidgets(
      'sheet carries the destination into ${form.label} and cancellation',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: StringsLocalizations.localizationsDelegates,
            supportedLocales: const [Locale('en')],
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => showSaveBottomSheet(
                  context,
                  fixedCollection: collection,
                  onUploadDocument: () async => false,
                  onUploadFiles: (_) async => false,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        for (final label in ['Document', 'File', 'Note', 'Thing', 'Secret']) {
          expect(find.text(label), findsOneWidget);
        }
        await tester.ensureVisible(find.text(form.label));
        await tester.tap(find.text(form.label));
        await tester.pumpAndSettle();
        final page = tester.widget<BaseInfoPage>(
          find.byType(form.page().runtimeType),
        );
        expect(page.fixedCollection?.id, 42);
        await tester.tap(find.byIcon(Icons.arrow_back));
        await tester.pumpAndSettle();
        expect(find.byType(SaveBottomSheet), findsOneWidget);
        expect(
          tester
              .widget<SaveBottomSheet>(find.byType(SaveBottomSheet))
              .fixedCollection
              ?.id,
          42,
        );
      },
    );
  }
}
