import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:ente_crypto_api/ente_crypto_api.dart';
import 'package:ente_network/network.dart';
import 'package:ente_sharing/models/user.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:locker/models/file_type.dart';
import 'package:locker/services/collections/collections_service.dart';
import 'package:locker/services/collections/models/collection.dart';
import 'package:locker/services/configuration.dart';
import 'package:locker/services/db/locker_db.dart';
import 'package:locker/services/files/sync/models/file.dart';
import 'package:locker/ui/mixins/search_mixin.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../test_utils/configuration_test_util.dart';

void main() {
  late Directory root;
  late List<Collection> collections;

  setUpAll(() {
    registerCryptoApi(_TestCrypto());
    Network.instance = _TestNetwork();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    root = await setupLockerConfigurationForTest('search_collections');
    await Configuration.instance.setUserID(1);
    await Configuration.instance.setKey(base64Encode(Uint8List(32)));
    await LockerDB.instance.init();
    collections = [
      for (final (id, name) in [
        (1, 'QA common shelf A'),
        (2, 'QA common shelf B'),
      ])
        Collection(
          id,
          User(id: 1, email: 'test@example.com'),
          base64Encode(Uint8List(32)),
          base64Encode(Uint8List(24)),
          name,
          null,
          null,
          CollectionType.album,
          CollectionAttributes(),
          [],
          [],
          1,
        ),
    ];
    await LockerDB.instance.updateCollections(collections);
    await CollectionService.instance.init(
      await SharedPreferences.getInstance(),
    );
  });

  tearDown(() async {
    await LockerDB.instance.close();
    clearLockerConfigurationTestHandlers();
    await root.delete(recursive: true);
  });

  EnteFile note(int id) => EnteFile()
    ..uploadedFileID = id
    ..collectionID = 1
    ..ownerID = 1
    ..fileType = FileType.info
    ..encryptedKey = base64Encode(Uint8List(32))
    ..keyDecryptionNonce = base64Encode(Uint8List(24));

  Future<void> flush(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 15; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump(const Duration(milliseconds: 50));
      }
    });
  }

  testWidgets('search shows a shared Note once across matching collections', (
    tester,
  ) async {
    final shared = note(7)..title = 'QA unique note';
    final directMatch = note(8)..title = 'QA common shelf note';
    await tester.runAsync(() async {
      await LockerDB.instance.addFilesToCollection(collections[0], [shared]);
      await LockerDB.instance.addFilesToCollection(collections[1], [shared]);
    });
    await tester.pumpWidget(
      MaterialApp(home: _SearchPage(collections, [shared, directMatch])),
    );
    await tester.enterText(find.byType(TextField), 'QA common shelf');
    await tester.pump(const Duration(milliseconds: 300));
    await flush(tester);

    expect(find.text('QA common shelf A'), findsOneWidget);
    expect(find.text('QA common shelf B'), findsOneWidget);
    expect(find.text('QA unique note'), findsOneWidget);
    expect(find.text('QA common shelf note'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'unique');
    await tester.pump(const Duration(milliseconds: 300));
    await flush(tester);
    expect(find.text('QA unique note'), findsOneWidget);
    expect(find.text('QA common shelf note'), findsNothing);
    await tester.enterText(find.byType(TextField), 'no matching result');
    await tester.pump(const Duration(milliseconds: 300));
    await flush(tester);
    expect(find.text('QA unique note'), findsNothing);
    expect(find.text('QA common shelf A'), findsNothing);

    await tester.enterText(find.byType(TextField), '');
    await flush(tester);
    expect(find.text('QA common shelf A'), findsOneWidget);
    expect(find.text('QA common shelf B'), findsOneWidget);
    expect(find.text('QA unique note'), findsOneWidget);
    expect(find.text('QA common shelf note'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _TestNetwork implements Network {
  @override
  final enteDio = Dio();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SearchPage extends StatefulWidget {
  final List<Collection> collections;
  final List<EnteFile> files;

  const _SearchPage(this.collections, this.files);

  @override
  State<_SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<_SearchPage> with SearchMixin {
  List<Collection> _collections = [];
  List<EnteFile> _files = [];

  @override
  List<Collection> get allCollections => widget.collections;
  @override
  List<EnteFile> get allFiles => widget.files;

  @override
  void onSearchResultsChanged(
    List<Collection> collections,
    List<EnteFile> files,
  ) => setState(() {
    _collections = collections;
    _files = files;
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        TextField(onChanged: updateSearchQuery),
        for (final collection in _collections) Text(collection.name!),
        for (final file in _files) Text(file.displayName),
      ],
    ),
  );
}

// Crypto is outside this test: keep SQLite payloads readable.
class _TestCrypto implements CryptoApi {
  @override
  Uint8List base642bin(String value) => base64Decode(value);
  @override
  String bin2base64(Uint8List value, {bool urlSafe = false}) =>
      base64Encode(value);
  @override
  Uint8List generateKey() => Uint8List(32);
  @override
  Uint8List decryptSync(Uint8List source, Uint8List key, Uint8List nonce) =>
      source;
  @override
  EncryptionResult encryptSync(Uint8List source, Uint8List key) =>
      EncryptionResult(
        encryptedData: source,
        nonce: Uint8List(24),
        header: Uint8List(24),
      );
  @override
  Future<EncryptionResult> encryptData(Uint8List source, Uint8List key) async =>
      encryptSync(source, key);
  @override
  Future<Uint8List> decryptData(
    Uint8List source,
    Uint8List key,
    Uint8List header,
  ) async => source;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
