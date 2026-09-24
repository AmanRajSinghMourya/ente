import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:ente_configuration/base_configuration.dart';
import 'package:ente_network/network.dart';
import 'package:ente_sharing/models/user.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:locker/core/errors.dart';
import 'package:locker/services/collections/collections_api_client.dart';
import 'package:locker/services/collections/collections_service.dart';
import 'package:locker/services/collections/models/collection.dart';
import 'package:locker/services/files/sync/models/file.dart';
import 'package:locker/services/trash/trash_service.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_utils/configuration_test_util.dart';

void main() {
  final service = CollectionService.instance;
  final requests = <String>[];
  final logs = <LogRecord>[];
  final originalNetwork = Network.instance;
  late Directory root;
  late StreamSubscription<LogRecord> logSubscription;
  late Future<ResponseBody> Function(RequestOptions) respond;

  setUpAll(() async {
    root = await setupLockerConfigurationForTest('post_mutation_sync');
    Network.instance = _TestNetwork();
    Network.instance.enteDio.httpClientAdapter = _ResponseAdapter((options) {
      requests.add(options.path);
      return respond(options);
    });
    await CollectionApiClient.instance.init();
    final preferences = await SharedPreferences.getInstance();
    await service.init(preferences);
    await TrashService.instance.init(preferences);
    logSubscription = Logger('CollectionService').onRecord.listen(logs.add);
  });

  setUp(() {
    requests.clear();
    logs.clear();
  });

  tearDownAll(() async {
    await logSubscription.cancel();
    Network.instance.enteDio.close();
    Network.instance = originalNetwork;
    clearLockerConfigurationTestHandlers();
    await root.delete(recursive: true);
  });

  test('waits for reconciliation before completing the action', () async {
    final started = Completer<void>();
    final response = Completer<ResponseBody>();
    respond = (_) {
      started.complete();
      return response.future;
    };
    var completed = false;
    final sync = service.syncAfterMutation().then((_) => completed = true);
    await started.future;
    expect(completed, isFalse);

    response.complete(_emptyCollections());
    await sync;
    expect(completed, isTrue);
    expect(requests, ['/collections/v2']);
  });

  test(
    'logs a collection refresh timeout without failing the action',
    () async {
      respond = (options) async => throw _timeout(options);

      await service.syncAfterMutation(includeTrash: true);

      expect(requests, ['/collections/v2']);
      expect(
        logs.any(
          (record) =>
              record.level == Level.WARNING && record.error is DioException,
        ),
        isTrue,
      );
    },
  );

  test(
    'refreshes unchanged collections before handling a trash timeout',
    () async {
      respond = (options) async {
        if (options.path == '/collections/v2') return _emptyCollections();
        throw _timeout(options);
      };

      await service.syncAfterMutation(includeTrash: true);

      expect(requests, ['/collections/v2', '/trash/v2/diff']);
      expect(logs.any((record) => record.error is DioException), isTrue);
    },
  );

  test('normal sync still propagates an expired session', () async {
    respond = (_) async => ResponseBody.fromString('{}', 401);

    await expectLater(service.sync(), throwsA(isA<UnauthorizedError>()));
  });

  test('a timeout from the trash mutation itself still fails', () async {
    respond = (options) async => throw _timeout(options);
    final collection = Collection(
      1,
      User(id: 1, email: 'test@example.com'),
      '',
      null,
      'Documents',
      null,
      null,
      CollectionType.folder,
      CollectionAttributes(),
      [],
      [],
      0,
    );

    await expectLater(
      service.trashFile(EnteFile()..uploadedFileID = 10, collection),
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.receiveTimeout,
        ),
      ),
    );
    expect(requests, ['/files/trash']);
  });
}

ResponseBody _emptyCollections() => ResponseBody.fromString(
  '{"collections":[]}',
  200,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

DioException _timeout(RequestOptions options) => DioException(
  requestOptions: options,
  type: DioExceptionType.receiveTimeout,
);

class _ResponseAdapter implements HttpClientAdapter {
  _ResponseAdapter(this.respond);

  final Future<ResponseBody> Function(RequestOptions) respond;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => respond(options);

  @override
  void close({bool force = false}) {}
}

class _TestNetwork implements Network {
  @override
  final Dio enteDio = Dio(BaseOptions(baseUrl: 'https://example.invalid'));

  @override
  Dio getDio() => enteDio;

  @override
  Future<void> init(BaseConfiguration configuration) async {}
}
