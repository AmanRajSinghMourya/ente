import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:ente_base/models/key_attributes.dart';
import 'package:ente_components/ente_components.dart';
import 'package:ente_crypto_api/ente_crypto_api.dart';
import 'package:ente_crypto_dart_adapter/ente_crypto_dart_adapter.dart';
import 'package:ente_network/network.dart';
import 'package:ente_sharing/models/user.dart';
import 'package:ente_strings/ente_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:locker/models/selected_files.dart';
import 'package:locker/services/collections/collections_api_client.dart';
import 'package:locker/services/collections/collections_service.dart';
import 'package:locker/services/collections/models/collection.dart';
import 'package:locker/services/configuration.dart';
import 'package:locker/services/db/locker_db.dart';
import 'package:locker/services/favorites_service.dart';
import 'package:locker/services/files/sync/models/file.dart';
import 'package:locker/ui/viewer/actions/file_selection_overlay_bar.dart';
import 'package:locker/utils/crypto_helper.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/test_utils/configuration_test_util.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final config = Configuration.instance;
  final db = LockerDB.instance;
  final collections = CollectionService.instance;
  final favorites = FavoritesService.instance;
  late CollectionApiClient api;
  final requests = <Map<String, dynamic>>[];
  late Directory root;
  late Uint8List masterKey;
  late CryptoKeyPair keyPair;
  late Collection important;
  late Collection incoming;
  late Collection uncategorized;
  late Collection folder;
  late EnteFile file;
  late Uint8List fileKey;

  Collection collection(
    int id,
    CollectionType type, {
    int ownerID = 1,
    bool isDeleted = false,
  }) {
    final key = CryptoUtil.generateKey();
    final wrapped = CryptoUtil.encryptSync(key, masterKey);
    return Collection(
      id,
      User(id: ownerID, email: '$ownerID@example.com'),
      ownerID == 1
          ? CryptoUtil.bin2base64(wrapped.encryptedData!)
          : CryptoUtil.bin2base64(CryptoUtil.sealSync(key, keyPair.publicKey)),
      ownerID == 1 ? CryptoUtil.bin2base64(wrapped.nonce!) : null,
      'Collection $id',
      null,
      null,
      type,
      CollectionAttributes(),
      [
        if (ownerID != 1)
          User(id: 1, email: '1@example.com', role: 'COLLABORATOR'),
      ],
      [],
      0,
      isDeleted: isDeleted,
    );
  }

  EnteFile fileIn(Collection collection, Uint8List key, {int id = 99}) {
    final wrapped = CryptoUtil.encryptSync(
      key,
      CryptoHelper.instance.getCollectionKey(collection),
    );
    return EnteFile()
      ..uploadedFileID = id
      ..collectionID = collection.id
      ..ownerID = 1
      ..title = 'private document.pdf'
      ..encryptedKey = CryptoUtil.bin2base64(wrapped.encryptedData!)
      ..keyDecryptionNonce = CryptoUtil.bin2base64(wrapped.nonce!);
  }

  Future<void> startFavorites() async {
    await favorites.init();
    addTearDown(favorites.dispose);
  }

  setUpAll(() async {
    root = await setupLockerConfigurationForTest('favorites');
    registerCryptoApi(const EnteCryptoDartAdapter());
    await CryptoUtil.init();
    masterKey = CryptoUtil.generateKey();
    keyPair = CryptoUtil.generateKeyPair();
    await config.setUserID(1);
    await config.setKey(CryptoUtil.bin2base64(masterKey));
    await config.setSecretKey(CryptoUtil.bin2base64(keyPair.secretKey));
    await config.setKeyAttributes(
      KeyAttributes(
        '',
        '',
        '',
        CryptoUtil.bin2base64(keyPair.publicKey),
        '',
        '',
        0,
        0,
        '',
        '',
        '',
        '',
      ),
    );
    await db.init();
    PackageInfo.setMockInitialValues(
      appName: 'Locker',
      packageName: 'io.ente.locker',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    await Network.instance.init(config);
    Network.instance.enteDio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'POST') {
            requests.add(
              jsonDecode(jsonEncode(options.data)) as Map<String, dynamic>,
            );
          }
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: options.path == '/collections/v2'
                  ? {'collections': []}
                  : {},
            ),
          );
        },
      ),
    );
    await collections.init(await SharedPreferences.getInstance());
    api = CollectionApiClient.instance;
    await api.init();
  });

  setUp(() async {
    await db.clearTable();
    collections.clearCache();
    favorites.clearCache();
    requests.clear();
    incoming = collection(1, CollectionType.folder, ownerID: 2);
    important = collection(10, CollectionType.favorites);
    uncategorized = collection(20, CollectionType.uncategorized);
    folder = collection(30, CollectionType.folder);
    await db.updateCollections([incoming, important, uncategorized, folder]);
    fileKey = CryptoUtil.generateKey();
    file = fileIn(important, fileKey);
    // Inject a colliding shared row, then replay the genuine Important row.
    await db.addFilesToCollection(incoming, [
      fileIn(incoming, CryptoUtil.generateKey()),
    ]);
    await db.addFilesToCollection(important, [file]);
  });

  tearDownAll(() async {
    await db.close();
    clearLockerConfigurationTestHandlers();
    await root.delete(recursive: true);
  });

  for (final bulk in [false, true]) {
    for (final existingOwnedFolder in [false, true]) {
      testWidgets(
        '${bulk ? 'bulk' : 'single'} unmark ignores incoming membership, owned folder: $existingOwnedFolder',
        (tester) async {
          if (existingOwnedFolder) {
            await db.addFilesToCollection(folder, [fileIn(folder, fileKey)]);
            await db.addFilesToCollection(important, [file]);
          }
          await startFavorites();

          if (bulk) {
            await favorites.updateFavorites([file], false);
          } else {
            await favorites.removeFromFavorites(file);
          }

          final destination = existingOwnedFolder ? folder : uncategorized;
          expect(requests.single['toCollectionID'], destination.id);
          final sentFile = (requests.single['files'] as List).single as Map;
          expect(
            CryptoHelper.instance.getFileKey(
              sentFile['encryptedKey'] as String,
              sentFile['keyDecryptionNonce'] as String,
              CryptoHelper.instance.getCollectionKey(destination),
            ),
            fileKey,
          );
          expect(
            () => CryptoHelper.instance.getFileKey(
              sentFile['encryptedKey'] as String,
              sentFile['keyDecryptionNonce'] as String,
              CryptoHelper.instance.getCollectionKey(incoming),
            ),
            throwsA(anything),
          );
          expect(await favorites.isFavorite(file), isFalse);
          expect(await db.getFilesInCollection(important), isEmpty);
          final savedFile = (await db.getFilesInCollection(destination)).single;
          expect(await collections.getFileKey(savedFile), fileKey);
        },
      );
    }
  }

  testWidgets('unmark skips a deleted owned destination', (tester) async {
    final deleted = collection(0, CollectionType.folder, isDeleted: true);
    await db.updateCollections([deleted]);
    await db.addFilesToCollection(deleted, [fileIn(deleted, fileKey)]);
    await db.addFilesToCollection(important, [file]);
    await startFavorites();

    await favorites.removeFromFavorites(file);

    expect(requests.single['toCollectionID'], uncategorized.id);
  });

  testWidgets('selection bar unmarks Important without sharing its key', (
    tester,
  ) async {
    await startFavorites();
    final selection = SelectedFiles()..toggleSelection(file);
    await tester.pumpWidget(
      MaterialApp(
        theme: ComponentTheme.lightTheme(app: ComponentApp.locker),
        localizationsDelegates: StringsLocalizations.localizationsDelegates,
        supportedLocales: const [Locale('en')],
        home: Scaffold(
          body: FileSelectionOverlayBar(
            selectedFiles: selection,
            files: [file],
          ),
        ),
      ),
    );

    await tester.tap(find.text('Unimportant'));
    await tester.pumpAndSettle();

    expect(selection.files, isEmpty);
    expect(await favorites.isFavorite(file), isFalse);
    expect(requests.single['toCollectionID'], uncategorized.id);
    final savedFile = (await db.getFilesInCollection(uncategorized)).single;
    expect(await collections.getFileKey(savedFile), fileKey);
  });

  testWidgets('mark then unmark preserves an owned file and its folder', (
    tester,
  ) async {
    final ownedFile = fileIn(folder, fileKey, id: 100);
    await db.addFilesToCollection(folder, [ownedFile]);
    await startFavorites();

    await favorites.addToFavorites(ownedFile);
    expect(await favorites.isFavorite(ownedFile), isTrue);
    await favorites.removeFromFavorites(ownedFile);

    expect(await favorites.isFavorite(ownedFile), isFalse);
    expect(requests.first['collectionID'], important.id);
    expect(requests.last['toCollectionID'], folder.id);
    final savedFile = (await db.getFilesInCollection(folder)).single;
    expect(await collections.getFileKey(savedFile), fileKey);
  });

  for (final invalidPart in [
    'source',
    'destination',
    'file',
    'deleted source',
    'deleted destination',
  ]) {
    testWidgets('move rejects $invalidPart before changing or sending keys', (
      tester,
    ) async {
      final source = invalidPart == 'source'
          ? incoming
          : invalidPart == 'deleted source'
          ? important.copyWith(isDeleted: true)
          : important;
      final destination = invalidPart == 'destination'
          ? incoming
          : invalidPart == 'deleted destination'
          ? folder.copyWith(isDeleted: true)
          : folder;
      final files = [
        file,
        if (invalidPart == 'file')
          fileIn(important, fileKey, id: 100)..ownerID = 2,
      ];
      final originalKey = file.encryptedKey;
      final originalNonce = file.keyDecryptionNonce;

      await expectLater(
        api.move(files, source, destination),
        throwsA(isA<AssertionError>()),
      );

      expect(requests, isEmpty);
      expect(file.collectionID, important.id);
      expect(file.encryptedKey, originalKey);
      expect(file.keyDecryptionNonce, originalNonce);
    });
  }

  testWidgets(
    'move validates files beyond the first batch before sending anything',
    (tester) async {
      final files = List.generate(
        101,
        (id) => fileIn(important, fileKey, id: id),
      );
      files.last.ownerID = 2;

      await expectLater(
        api.move(files, important, folder),
        throwsA(isA<AssertionError>()),
      );

      expect(requests, isEmpty);
      expect(files.every((file) => file.collectionID == important.id), isTrue);
    },
  );

  testWidgets('explicit add to a collaborator collection remains supported', (
    tester,
  ) async {
    expect(incoming.canAdd(1), isTrue);

    await api.addToCollection(incoming, [file]);

    expect(requests.single['collectionID'], incoming.id);
    final sentFile = (requests.single['files'] as List).single as Map;
    expect(
      CryptoHelper.instance.getFileKey(
        sentFile['encryptedKey'] as String,
        sentFile['keyDecryptionNonce'] as String,
        CryptoHelper.instance.getCollectionKey(incoming),
      ),
      fileKey,
    );
  });
}
