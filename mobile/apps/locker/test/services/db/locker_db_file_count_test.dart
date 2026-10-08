import 'dart:io';

import 'package:ente_sharing/models/user.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:locker/services/collections/models/collection.dart';
import 'package:locker/services/db/locker_db.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../test_utils/configuration_test_util.dart';

void main() {
  late Directory root;
  late Database raw;

  Collection collection(int id) => Collection(
    id,
    User(id: 1, email: 'a@b.c'),
    '',
    null,
    'Collection $id',
    null,
    null,
    CollectionType.folder,
    CollectionAttributes(),
    const [],
    const [],
    0,
  );

  Future<void> addFile(int fileId, List<int> collectionIds) async {
    await raw.insert('files', {
      'uploaded_file_id': fileId,
      'collection_id': collectionIds.first,
      'payload_encrypted_data': 'data',
      'payload_decryption_header': 'header',
    });
    for (final collectionId in collectionIds) {
      await raw.insert('collection_files', {
        'collection_id': collectionId,
        'uploaded_file_id': fileId,
      });
    }
  }

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    root = await setupLockerConfigurationForTest('locker_db_file_count');
    await LockerDB.instance.init();
    raw = await databaseFactoryFfi.openDatabase(
      join(root.path, LockerDB.databaseName),
    );
  });

  tearDown(() async {
    await raw.close();
    await LockerDB.instance.close();
    clearLockerConfigurationTestHandlers();
    await root.delete(recursive: true);
  });

  test('counts the files in each collection', () async {
    await addFile(1, [10]);
    await addFile(2, [10, 20]);
    await addFile(3, [20]);
    await addFile(4, [20]);

    expect(await LockerDB.instance.getFileCount(collection(10)), 2);
    expect(await LockerDB.instance.getFileCount(collection(20)), 3);
  });

  test('an empty collection counts zero', () async {
    await addFile(1, [10]);

    expect(await LockerDB.instance.getFileCount(collection(30)), 0);
  });

  test('a membership without its file row is not counted', () async {
    await addFile(1, [10]);
    await raw.insert('collection_files', {
      'collection_id': 10,
      'uploaded_file_id': 99,
    });

    expect(await LockerDB.instance.getFileCount(collection(10)), 1);
  });

  test('matches the rows getFilesInCollection reads', () async {
    await addFile(1, [10, 20]);
    await addFile(2, [10]);
    await raw.insert('collection_files', {
      'collection_id': 10,
      'uploaded_file_id': 99,
    });

    final joined = await raw.rawQuery(
      '''
      SELECT f.uploaded_file_id
      FROM files f
      INNER JOIN collection_files cf ON f.uploaded_file_id = cf.uploaded_file_id
      WHERE cf.collection_id = ?
    ''',
      [10],
    );
    final distinctIds = joined.map((row) => row['uploaded_file_id']).toSet();

    expect(
      await LockerDB.instance.getFileCount(collection(10)),
      distinctIds.length,
    );
  });
}
