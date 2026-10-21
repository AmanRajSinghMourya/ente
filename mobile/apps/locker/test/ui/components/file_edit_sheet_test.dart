import 'dart:io';

import 'package:ente_components/ente_components.dart';
import 'package:ente_sharing/models/user.dart';
import 'package:ente_strings/ente_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:locker/services/collections/models/collection.dart';
import 'package:locker/services/configuration.dart';
import 'package:locker/services/files/sync/models/file.dart';
import 'package:locker/ui/components/file_edit_sheet.dart';

import '../../test_utils/configuration_test_util.dart';

void main() {
  late Directory testRoot;

  setUp(() async {
    testRoot = await setupLockerConfigurationForTest('file_edit');
    await Configuration.instance.setUserID(1);
  });

  tearDown(() async {
    clearLockerConfigurationTestHandlers();
    await testRoot.delete(recursive: true);
  });

  final collection = Collection(
    10,
    User(id: 1, email: 'a@b.c'),
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

  Future<void> openEditor(
    WidgetTester tester,
    String fileName,
    ValueChanged<FileEditSheetResult?> onSaved,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: StringsLocalizations.localizationsDelegates,
        supportedLocales: const [Locale('en')],
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => onSaved(
              await showFileEditSheet(
                context,
                file: EnteFile()..title = fileName,
                collections: [collection],
              ),
            ),
            child: const Text('edit'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('edit'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TagChipComponent, 'Documents'));
    await tester.pumpAndSettle();
  }

  for (final (original, baseName, input, expected) in [
    ('scan.jpeg', 'scan', 'Passport', 'Passport.jpeg'),
    ('scan.JPEG', 'scan', 'Passport', 'Passport.JPEG'),
    ('archive.tar.gz', 'archive.tar', 'backup.tar', 'backup.tar.gz'),
    ('README', 'README', 'Notes', 'Notes'),
    ('.env', '.env', '.config', '.config'),
    ('scan.pdf', 'scan', 'scan', 'scan.pdf'),
    ('scan.jpeg', 'scan', 'scan ', 'scan .jpeg'),
    ('scan.JPEG', 'scan', ' scan  ', ' scan  .JPEG'),
    ('scan.jpeg.jpeg', 'scan.jpeg', 'scan.jpeg', 'scan.jpeg.jpeg'),
    ('scan.jpeg.jpeg', 'scan.jpeg', 'scan.jpeg ', 'scan.jpeg .jpeg'),
    (
      'Invoice 2024 .pdf',
      'Invoice 2024 ',
      'Invoice 2024 ',
      'Invoice 2024 .pdf',
    ),
    (
      'Invoice 2024 .pdf',
      'Invoice 2024 ',
      ' Invoice 2024  ',
      ' Invoice 2024  .pdf',
    ),
    ('  .pdf', '  ', '  ', '  .pdf'),
    ('foo.pdf/', 'foo/', 'foo/', 'foo.pdf/'),
    ('scan.jpeg', 'scan', 'Passport.pdf', 'Passport.pdf.jpeg'),
  ]) {
    testWidgets('rename $original to $input preserves its extension', (
      tester,
    ) async {
      FileEditSheetResult? saved;
      await openEditor(tester, original, (result) => saved = result);
      expect(find.widgetWithText(TextField, baseName), findsOneWidget);
      await tester.enterText(find.byType(TextField), input);
      await tester.pump();
      await tester.tap(find.widgetWithText(ButtonComponent, 'Save'));
      await tester.pumpAndSettle();
      expect(saved!.title, expected);
      expect(saved!.selectedCollections.map((c) => c.id), [10]);
    });
  }

  testWidgets('an empty base name cannot be saved', (tester) async {
    await openEditor(tester, 'scan.jpeg', (_) {});
    for (final input in ['', '   ']) {
      await tester.enterText(find.byType(TextField), input);
      await tester.pump();
      expect(
        tester
            .widget<ButtonComponent>(
              find.widgetWithText(ButtonComponent, 'Save'),
            )
            .onTap,
        isNull,
      );
    }
  });

  testWidgets('a legacy whitespace basename cannot be cleared', (tester) async {
    await openEditor(tester, '  .pdf', (_) {});
    for (final input in ['', ' ', '   ']) {
      await tester.enterText(find.byType(TextField), input);
      await tester.pump();
      expect(
        tester
            .widget<ButtonComponent>(
              find.widgetWithText(ButtonComponent, 'Save'),
            )
            .onTap,
        isNull,
      );
    }
  });
}
