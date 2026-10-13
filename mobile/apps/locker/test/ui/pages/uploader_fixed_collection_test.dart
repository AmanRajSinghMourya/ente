import 'dart:io';

import 'package:ente_components/ente_components.dart';
import 'package:ente_sharing/models/user.dart';
import 'package:ente_strings/ente_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:locker/services/collections/models/collection.dart';
import 'package:locker/ui/pages/file_upload_screen_v2.dart';
import 'package:locker/ui/pages/uploader_page.dart';

void main() {
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

  for (final pickFiles in [true, false]) {
    testWidgets(
      'fixed ${pickFiles ? 'file picker' : 'scan callback'} skips collection lookup',
      (tester) async {
        const channel = MethodChannel('miguelruivo.flutter.plugins.filepicker');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (_) async => [
            {'name': 'test.pdf', 'path': '/upload/test.pdf', 'size': 1},
          ],
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: StringsLocalizations.localizationsDelegates,
            supportedLocales: const [Locale('en')],
            home: _UploadPage(collection: collection, pickFiles: pickFiles),
          ),
        );
        await tester.tap(find.text('upload'));
        await tester.pumpAndSettle();
        final screen = tester.widget<FileUploadScreenV2>(
          find.byType(FileUploadScreenV2),
        );
        expect(screen.fixedCollection?.id, 42);
        expect(screen.collections, isEmpty);
        expect(find.text('New collection'), findsNothing);

        await tester.tap(find.byIcon(Icons.arrow_back));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ButtonComponent, 'Discard'));
        await tester.pumpAndSettle();
        expect(find.text('cancelled'), findsOneWidget);
      },
    );
  }
}

class _UploadPage extends UploaderPage {
  const _UploadPage({required this.collection, required this.pickFiles});

  final Collection collection;
  final bool pickFiles;

  @override
  State<_UploadPage> createState() => _UploadPageState();
}

class _UploadPageState extends UploaderPageState<_UploadPage> {
  bool? _didUpload;

  @override
  void onFileUploadComplete() {}

  @override
  Widget build(BuildContext context) => Scaffold(
    body: TextButton(
      onPressed: () async {
        final didUpload = widget.pickFiles
            ? await addFile(fixedCollection: widget.collection)
            : await uploadFiles([
                File('/upload/test.pdf'),
              ], fixedCollection: widget.collection);
        setState(() => _didUpload = didUpload);
      },
      child: Text(_didUpload == false ? 'cancelled' : 'upload'),
    ),
  );
}
