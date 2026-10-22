import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:ente_components/ente_components.dart';
import 'package:ente_crypto_api/ente_crypto_api.dart';
import 'package:ente_network/network.dart';
import 'package:ente_sharing/models/user.dart';
import 'package:ente_strings/ente_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:locker/models/file_type.dart';
import 'package:locker/services/collections/collections_api_client.dart';
import 'package:locker/services/collections/collections_service.dart';
import 'package:locker/services/collections/models/collection.dart';
import 'package:locker/services/configuration.dart';
import 'package:locker/services/db/locker_db.dart';
import 'package:locker/services/favorites_service.dart';
import 'package:locker/services/files/sync/models/file.dart';
import 'package:locker/services/files/sync/models/file_magic.dart';
import 'package:locker/ui/pages/personal_note_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../test_utils/configuration_test_util.dart';

void main() {
  final network = _TestNetwork();
  late Directory root;
  late _Server server;
  late List<Collection> collections;

  setUpAll(() {
    registerCryptoApi(_TestCrypto());
    Network.instance = network;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    root = await setupLockerConfigurationForTest('info_save_retry');
    await Configuration.instance.setUserID(1);
    await Configuration.instance.setKey(base64Encode(Uint8List(32)));
    await LockerDB.instance.init();
    collections = [
      for (final (id, name, type) in [
        (1, 'Important', CollectionType.favorites),
        (2, 'Second', CollectionType.album),
        (3, 'Third', CollectionType.album),
      ])
        Collection(
          id,
          User(id: 1, email: 'test@example.com'),
          base64Encode(Uint8List(32)),
          base64Encode(Uint8List(24)),
          name,
          null,
          null,
          type,
          CollectionAttributes(),
          [],
          [],
          1,
        ),
    ];
    await LockerDB.instance.updateCollections(collections);
    await LockerDB.instance.setSyncTime(1);
    CollectionService.instance.clearCache();
    await CollectionApiClient.instance.init();
    await CollectionService.instance.init(
      await SharedPreferences.getInstance(),
    );
    await FavoritesService.instance.init();
    server = _Server();
    network.enteDio.interceptors
      ..clear()
      ..add(InterceptorsWrapper(onRequest: server.handle));
  });

  tearDown(() async {
    FavoritesService.instance.dispose();
    await LockerDB.instance.close();
    clearLockerConfigurationTestHandlers();
    await root.delete(recursive: true);
  });

  Future<void> flush(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 15; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump(const Duration(milliseconds: 50));
      }
    });
  }

  Future<void> openNote(WidgetTester tester, {EnteFile? file}) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: StringsLocalizations.localizationsDelegates,
        supportedLocales: const [Locale('en')],
        home: PersonalNotePage(existingFile: file),
      ),
    );
    await flush(tester);
  }

  Future<void> save(WidgetTester tester) async {
    await tester.pump();
    await tester.tap(find.widgetWithText(ButtonComponent, 'Save'));
    await flush(tester);
  }

  testWidgets(
    'failed collection edit stays editable and retries the same Note',
    (tester) async {
      final file = server.note(7);
      await tester.runAsync(
        () => LockerDB.instance.addFilesToCollection(collections.first, [file]),
      );
      await openNote(tester, file: file);
      await tester.tap(find.text('Second'));
      await save(tester);

      expect(find.text('Error'), findsOneWidget);
      expect(find.widgetWithText(ButtonComponent, 'Save'), findsOneWidget);
      expect(server.members[1], {7});
      expect(server.members[2], isEmpty);

      Navigator.of(tester.element(find.text('Error'))).pop();
      await flush(tester);
      server.rejectAdds = false;
      await save(tester);
      expect(server.notes.keys, [7]);
      expect(server.members[2], {7});
      expect(find.widgetWithText(ButtonComponent, 'Save'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 3));
    },
  );
}

class _Server {
  final notes = <int, Map<String, dynamic>>{};
  final versions = <int, int>{};
  final members = <int, Set<int>>{1: {}, 2: {}, 3: {}};
  bool rejectAdds = true;
  Completer<void>? pauseSync;

  EnteFile note(int id) {
    notes[id] = {'title': 'Note', 'content': 'Original content'};
    versions[id] = 1;
    members[1]!.add(id);
    final encoded = jsonEncode({
      'info': {'type': 'note', 'data': notes[id]},
    });
    return EnteFile()
      ..uploadedFileID = id
      ..collectionID = 1
      ..ownerID = 1
      ..fileType = FileType.info
      ..title = 'Note'
      ..encryptedKey = base64Encode(Uint8List(32))
      ..keyDecryptionNonce = base64Encode(Uint8List(24))
      ..pubMmdEncodedJson = encoded
      ..pubMagicMetadata = PubMagicMetadata.fromJson(jsonDecode(encoded));
  }

  Future<void> handle(
    RequestOptions request,
    RequestInterceptorHandler h,
  ) async {
    final data = request.data == null
        ? null
        : jsonDecode(jsonEncode(request.data));
    Object response = <String, dynamic>{};
    switch (request.path) {
      case '/files/meta':
        final id = 100 + notes.length;
        versions[id] = data['pubMagicMetadata']['version'] as int;
        final metadata = jsonDecode(
          utf8.decode(base64Decode(data['pubMagicMetadata']['data'] as String)),
        );
        notes[id] = Map<String, dynamic>.from(metadata['info']['data'] as Map);
        members[data['collectionID']]!.add(id);
        response = {'id': id, 'ownerID': 1, 'updationTime': 1};
      case '/files/public-magic-metadata':
        for (final item in data['metadataList'] as List) {
          if (item['magicMetadata']['version'] != versions[item['id']]) {
            h.reject(
              DioException(
                requestOptions: request,
                response: Response(requestOptions: request, statusCode: 409),
                type: DioExceptionType.badResponse,
              ),
            );
            return;
          }
          versions[item['id']] = versions[item['id']]! + 1;
          final metadata = jsonDecode(
            utf8.decode(base64Decode(item['magicMetadata']['data'] as String)),
          );
          notes[item['id']] = Map<String, dynamic>.from(
            metadata['info']['data'] as Map,
          );
        }
      case '/collections/add-files':
        if (rejectAdds && data['collectionID'] == 2) {
          h.reject(
            DioException(
              requestOptions: request,
              response: Response(requestOptions: request, statusCode: 403),
              type: DioExceptionType.badResponse,
            ),
          );
          return;
        }
        for (final file in data['files'] as List) {
          members[data['collectionID']]!.add(file['id'] as int);
        }
      case '/collections/v2':
        if (members[2]!.isNotEmpty || members[3]!.isNotEmpty) {
          await pauseSync?.future;
        }
        response = {'collections': <dynamic>[]};
      default:
        throw StateError('Unexpected request ${request.path}');
    }
    h.resolve(
      Response(requestOptions: request, data: response, statusCode: 200),
    );
  }
}

class _TestNetwork implements Network {
  @override
  final enteDio = Dio(BaseOptions(baseUrl: 'https://test.invalid'));
  @override
  Dio getDio() => enteDio;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Crypto is outside these tests: keep payloads readable at the HTTP boundary.
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
