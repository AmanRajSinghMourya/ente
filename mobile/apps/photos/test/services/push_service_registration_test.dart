import 'package:dio/dio.dart';
// Firebase's test helper is supplied by its platform dependency.
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/service_locator.dart';
import 'package:photos/services/notification_key_service.dart';
import 'package:photos/services/push_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  final requests = <Map<String, dynamic>>[];
  var prepareCalls = 0;
  var failPreparation = false;
  var failRegistration = false;
  const enrollment = {'version': 1, 'publicKey': 'synthetic-public-key'};

  setUpAll(() async {
    setupFirebaseCoreMocks();
    SharedPreferences.setMockInitialValues({
      Configuration.tokenKey: 'synthetic-session',
      'remote_flags': '{}',
    });
    FlutterSecureStorage.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(Map<String, dynamic>.from(options.data as Map));
          if (failRegistration) {
            handler.reject(DioException(requestOptions: options));
          } else {
            handler.resolve(Response(requestOptions: options, statusCode: 200));
          }
        },
      ),
    );
    ServiceLocator.instance.init(
      prefs,
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
      await Configuration.instance.init(prefs);
    } on MissingPluginException {
      // Path-provider initialization is unavailable in the test process.
    }
    await Configuration.instance.setKey('synthetic-account-key');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/firebase_messaging'),
      (call) async {
        switch (call.method) {
          case 'Messaging#getToken':
            return {'token': 'synthetic-fcm'};
          case 'Messaging#getAPNSToken':
            return {'token': 'synthetic-apns'};
          default:
            throw StateError('Unexpected Firebase call: ${call.method}');
        }
      },
    );
    messenger.setMockMethodCallHandler(NotificationKeyService.channel, (
      call,
    ) async {
      expect(call.method, 'prepare');
      expect(call.arguments, {'sessionToken': 'synthetic-session'});
      prepareCalls++;
      if (failPreparation) {
        throw PlatformException(code: 'notification_key_store');
      }
      return enrollment;
    });
  });

  setUp(() async {
    requests.clear();
    prepareCalls = 0;
    failPreparation = false;
    failRegistration = false;
    await prefs.remove(PushService.kFCMPushToken);
    await prefs.remove(PushService.kLastFCMTokenUpdationTime);
    await prefs.setBool('ls.internal_user_disabled', false);
  });

  test(
    'ordinary registration bypasses key preparation and retains token cache',
    () async {
      await prefs.setBool('ls.internal_user_disabled', true);
      failPreparation = true;
      await PushService.instance.init();
      expect(prepareCalls, 0);
      expect(requests.single['notification'], isNull);
      expect(prefs.getString(PushService.kFCMPushToken), 'synthetic-fcm');
      expect(prefs.getInt(PushService.kLastFCMTokenUpdationTime), isNotNull);
      await PushService.instance.init();
      expect(requests, hasLength(1));
    },
  );

  test(
    'failed key preparation registers token and retries enrollment next init',
    () async {
      failPreparation = true;
      await PushService.instance.init();
      expect(requests.single['notification'], isNull);
      expect(prefs.containsKey(PushService.kFCMPushToken), isFalse);
      expect(prefs.containsKey(PushService.kLastFCMTokenUpdationTime), isFalse);
      failPreparation = false;
      await PushService.instance.init();
      expect(prepareCalls, 2);
      expect(requests, hasLength(2));
      expect(requests.last['fcmToken'], 'synthetic-fcm');
      expect(prefs.getString(PushService.kFCMPushToken), 'synthetic-fcm');
      await PushService.instance.init();
      expect(prepareCalls, 2);
      expect(requests, hasLength(2));
    },
  );

  test(
    'failed server registration remains due for retry',
    () async {
      failRegistration = true;
      await PushService.instance.init();
      expect(prefs.containsKey(PushService.kFCMPushToken), isFalse);
      expect(prefs.containsKey(PushService.kLastFCMTokenUpdationTime), isFalse);
      failRegistration = false;
      await PushService.instance.init();
      expect(requests, hasLength(2));
      expect(prepareCalls, 2);
      expect(requests.map((r) => r['fcmToken']), everyElement('synthetic-fcm'));
      expect(prefs.getString(PushService.kFCMPushToken), 'synthetic-fcm');
    },
  );
}
