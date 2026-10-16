import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:computer/computer.dart';
import 'package:dio/dio.dart';
import 'package:ente_crypto/ente_crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/db/collections_db.dart';
import 'package:photos/models/api/collection/user.dart';
import 'package:photos/models/collection/collection.dart';
import 'package:photos/service_locator.dart';
import 'package:photos/services/collections_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'hiding persists notification privacy before the follow-up sync',
    () async {
      final directory = await Directory.systemTemp.createTemp('expiry_hide_');
      final previousPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(directory.path);
      addTearDown(() async {
        await (await CollectionsDB.instance.database).close();
        PathProviderPlatform.instance = previousPaths;
        await directory.delete(recursive: true);
        await Computer.shared().turnOff();
      });
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({Configuration.userIDKey: 1});
      final preferences = await SharedPreferences.getInstance();
      final syncStarted = Completer<void>();
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (options.method == 'PUT') {
                handler.resolve(Response(requestOptions: options, data: {}));
              } else {
                syncStarted.complete();
              }
            },
          ),
        );
      ServiceLocator.instance.init(
        preferences,
        dio,
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
      } on MissingPluginException {}
      CryptoUtil.init();
      await Computer.shared().turnOn(workersCount: 1);
      final masterKey = Uint8List(32);
      await Configuration.instance.setKey(CryptoUtil.bin2base64(masterKey));
      final encryptedKey = CryptoUtil.encryptSync(Uint8List(32), masterKey);
      final collection = Collection(
        44,
        User(id: 1, email: 'owner@example.com'),
        CryptoUtil.bin2base64(encryptedKey.encryptedData!),
        CryptoUtil.bin2base64(encryptedKey.nonce!),
        'Private',
        null,
        null,
        CollectionType.album,
        CollectionAttributes(),
        [],
        [],
        1,
      );
      final service = CollectionsService.instance;
      await service.init(preferences);
      service.collectionIDToCollections[collection.id] = collection;
      await CollectionsDB.instance.insert([collection]);
      expect(
        await CollectionsDB.instance.getVisibleCollectionName(44),
        'Private',
      );
      await service.updateMagicMetadata(collection, {'visibility': 2});
      await syncStarted.future;
      expect(await CollectionsDB.instance.getVisibleCollectionName(44), isNull);
    },
  );
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}
