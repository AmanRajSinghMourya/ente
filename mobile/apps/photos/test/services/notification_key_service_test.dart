import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos/services/notification_key_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'failed key preparation leaves notification enrollment unavailable',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(NotificationKeyService.channel, (
        _,
      ) async {
        throw PlatformException(code: 'notification_key_store');
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          NotificationKeyService.channel,
          null,
        ),
      );
      expect(
        await NotificationKeyService.prepare(sessionToken: 'synthetic-session'),
        isNull,
      );
    },
  );

  test('failed notification cleanup does not interrupt logout', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(NotificationKeyService.channel, (
      _,
    ) async {
      throw PlatformException(code: 'notification_key_store');
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        NotificationKeyService.channel,
        null,
      ),
    );
    await expectLater(NotificationKeyService.clear(), completes);
  });

  test(
    'failed preference sharing does not interrupt the settings toggle',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(NotificationKeyService.channel, (
        _,
      ) async {
        throw PlatformException(code: 'notification_key_store');
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          NotificationKeyService.channel,
          null,
        ),
      );
      await expectLater(NotificationKeyService.syncPreference(), completes);
    },
  );

  test(
    'NSE preparation returns public enrollment and cleanup uses the same bridge',
    () async {
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(NotificationKeyService.channel, (
        call,
      ) async {
        calls.add(call);
        return call.method == 'prepare'
            ? {'version': 1, 'publicKey': 'synthetic-public-key'}
            : null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          NotificationKeyService.channel,
          null,
        ),
      );

      final enrollment = await NotificationKeyService.prepare(
        sessionToken: 'synthetic-session',
      );
      expect(calls.single.method, 'prepare');
      expect(calls.single.arguments, {'sessionToken': 'synthetic-session'});
      expect(enrollment, {'version': 1, 'publicKey': 'synthetic-public-key'});

      await NotificationKeyService.syncPreference();
      expect(calls.last.method, 'syncPreference');
      expect(calls.last.arguments, isNull);

      await NotificationKeyService.clear();
      expect(calls.last.method, 'clear');
      expect(calls.last.arguments, isNull);
    },
  );
}
