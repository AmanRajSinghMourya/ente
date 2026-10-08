import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos/gateways/push/push_gateway.dart';

void main() {
  test('notification enrollment sends only the public key', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test'));
    RequestOptions? request;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          request = options;
          handler.resolve(Response(requestOptions: options, statusCode: 200));
        },
      ),
    );
    await PushGateway(dio).registerToken(
      fcmToken: 'synthetic-token',
      apnsToken: 'synthetic-apns-token',
      platform: 'ios',
      notification: {'version': 1, 'publicKey': 'synthetic-public-key'},
    );
    expect(request!.path, '/push/token');
    expect(request!.data, {
      'fcmToken': 'synthetic-token',
      'apnsToken': 'synthetic-apns-token',
      'platform': 'ios',
      'notification': {'version': 1, 'publicKey': 'synthetic-public-key'},
    });
    await PushGateway(dio).registerToken(
      fcmToken: 'android-token',
      platform: 'android',
      notification: null,
    );
    expect(request!.data, {
      'fcmToken': 'android-token',
      'apnsToken': null,
      'platform': 'android',
    });
  });

  test('postponed iOS delivery explicitly clears NSE enrollment', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test'));
    var requests = 0;
    RequestOptions? request;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests++;
          request = options;
          handler.resolve(Response(requestOptions: options, statusCode: 200));
        },
      ),
    );
    await PushGateway(dio).registerToken(
      fcmToken: 'synthetic-token',
      platform: 'ios',
      notification: null,
    );
    expect(requests, 1);
    expect(request!.data, {
      'fcmToken': 'synthetic-token',
      'apnsToken': null,
      'platform': 'ios',
      'notification': null,
    });
  });
}
