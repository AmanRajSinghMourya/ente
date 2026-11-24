import "dart:async";
import "dart:convert";
import "dart:io";

import "package:dio/dio.dart";
import "package:ente_base/models/accounts.dart";
import "package:ente_components/ente_components.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_secure_storage/flutter_secure_storage.dart";
import "package:flutter_test/flutter_test.dart";
import "package:package_info_plus/package_info_plus.dart";
import "package:photos/core/configuration.dart";
import "package:photos/core/error-reporting/super_logging.dart";
import "package:photos/core/exceptions.dart";
import "package:photos/ente_theme_data.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/account/user_service.dart";
import "package:photos/src/rust/frb_generated.dart";
import "package:photos/src/rust/third_party/ente_frb_lib/accounts/types.dart"
    show AccountDetailsResponse;
import "package:photos/ui/settings/security/security_settings_page.dart";
import "package:shared_preferences/shared_preferences.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const email = "person@example.com";
  final client = _AccountsClient();
  final requests = client.requests;

  setUpAll(() async {
    EntePhotosRust.initMock(api: _PhotosRustApi(client));
    addTearDown(EntePhotosRust.dispose);
    const paths = MethodChannel("plugins.flutter.io/path_provider");
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final directory = await Directory.systemTemp.createTemp(
      "security-settings",
    );
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(paths, null);
      await directory.delete(recursive: true);
    });
    SharedPreferences.setMockInitialValues({
      Configuration.emailKey: email,
      Configuration.userIDKey: 1,
      Configuration.hasSecureTokenKey: true,
    });
    FlutterSecureStorage.setMockInitialValues({
      Configuration.tokenKey: "token",
      Configuration.keyKey: "a2V5",
    });
    final preferences = await SharedPreferences.getInstance();
    ServiceLocator.instance.init(
      preferences,
      Dio(BaseOptions(headers: {HttpHeaders.userAgentHeader: "Photos"})),
      Dio(),
      Dio(),
      PackageInfo(
        appName: "Photos",
        packageName: "photos",
        version: "1.0.0",
        buildNumber: "1",
      ),
    );
    SuperLogging.appVersion = "test";
    await SuperLogging.main();
    await Configuration.instance.init(preferences);
    await UserService.instance.init();
  });

  setUp(() async {
    requests.clear();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(UserService.keyHasEnabledTwoFactor, true);
  });

  void respondWithProfile(Map<String, Object> profile) {
    requests.last.response.complete(
      AccountDetailsResponse(
        json: jsonEncode({
          "email": email,
          "usage": 0,
          "subscription": {
            "productID": "free",
            "storage": 0,
            "originalTransactionID": "",
            "paymentProvider": "",
            "expiryTime": 0,
            "price": "",
            "period": "",
          },
          "profileData": profile,
        }),
        totalStorage: 0,
        usedStorage: 0,
      ),
    );
  }

  test("account details keeps network failures local", () async {
    final refresh = UserService.instance.getUserDetailsV2();
    final assertion = expectLater(
      refresh,
      throwsA(allOf(isA<AccountsError_Network>(), isA<LocallyHandledError>())),
    );
    requests.single.response.completeError(
      const AccountsError.network(timeout: false),
    );
    await assertion;
  });

  testWidgets("2FA shows the cached status until a refresh confirms it", (
    tester,
  ) async {
    final userService = UserService.instance;

    await tester.pumpWidget(
      MaterialApp(
        theme: lightThemeData,
        localizationsDelegates: StringsLocalizations.localizationsDelegates,
        supportedLocales: StringsLocalizations.supportedLocales,
        home: const SecuritySettingsPage(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1));

    final context = tester.element(find.byType(SecuritySettingsPage));
    final row = find.widgetWithText(SettingsItem, context.strings.twofactor);
    final toggle = find.descendant(
      of: row,
      matching: find.byType(ToggleSwitchComponent),
    );
    final loading = find.descendant(
      of: row,
      matching: find.byType(LoadingComponent),
    );
    final retry = find.byTooltip(context.strings.retry);
    expect(loading, findsNothing);
    expect(tester.widget<ToggleSwitchComponent>(toggle).selected, isTrue);
    expect(tester.widget<ToggleSwitchComponent>(toggle).onChanged, isNull);

    requests.single.response.completeError(
      const AccountsError.network(timeout: false),
    );
    await tester.pumpAndSettle();
    expect(retry, findsOneWidget);
    expect(tester.widget<ToggleSwitchComponent>(toggle).onChanged, isNull);

    await tester.tap(retry);
    await tester.pump(const Duration(milliseconds: 1));
    expect(retry, findsNothing);
    expect(tester.widget<ToggleSwitchComponent>(toggle).onChanged, isNull);
    respondWithProfile({});
    await tester.pumpAndSettle();
    expect(retry, findsOneWidget);
    expect(tester.widget<ToggleSwitchComponent>(toggle).selected, isTrue);
    expect(tester.widget<ToggleSwitchComponent>(toggle).onChanged, isNull);
    expect(userService.hasEnabledTwoFactor(), isTrue);

    await tester.tap(retry);
    await tester.pump(const Duration(milliseconds: 1));
    respondWithProfile({"isTwoFactorEnabled": false});
    await tester.pumpAndSettle();
    expect(retry, findsNothing);
    expect(tester.widget<ToggleSwitchComponent>(toggle).selected, isFalse);
    expect(tester.widget<ToggleSwitchComponent>(toggle).onChanged, isNotNull);
    expect(userService.hasEnabledTwoFactor(), isFalse);
    expect(requests.map((request) => (request.token, request.memoryCount)), [
      ("token", false),
      ("token", false),
      ("token", false),
    ]);
  });

  testWidgets("2FA without a cached status refetches after an outside change", (
    tester,
  ) async {
    final userService = UserService.instance;
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(UserService.keyHasEnabledTwoFactor);

    await tester.pumpWidget(
      MaterialApp(
        theme: lightThemeData,
        localizationsDelegates: StringsLocalizations.localizationsDelegates,
        supportedLocales: StringsLocalizations.supportedLocales,
        home: const SecuritySettingsPage(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1));

    final context = tester.element(find.byType(SecuritySettingsPage));
    final row = find.widgetWithText(SettingsItem, context.strings.twofactor);
    final toggle = find.descendant(
      of: row,
      matching: find.byType(ToggleSwitchComponent),
    );
    final loading = find.descendant(
      of: row,
      matching: find.byType(LoadingComponent),
    );
    final retry = find.byTooltip(context.strings.retry);
    expect(loading, findsOneWidget);
    expect(toggle, findsNothing);

    requests.single.response.completeError(
      const AccountsError.network(timeout: false),
    );
    await tester.pumpAndSettle();
    expect(retry, findsOneWidget);
    expect(loading, findsNothing);
    expect(toggle, findsNothing);

    userService.getUserDetailsV2().ignore();
    await tester.pump(const Duration(milliseconds: 1));
    respondWithProfile({"isTwoFactorEnabled": false});
    await tester.pump(const Duration(milliseconds: 1));
    expect(retry, findsNothing);
    expect(tester.widget<ToggleSwitchComponent>(toggle).selected, isFalse);
    expect(tester.widget<ToggleSwitchComponent>(toggle).onChanged, isNull);

    respondWithProfile({"isTwoFactorEnabled": false});
    await tester.pumpAndSettle();
    expect(tester.widget<ToggleSwitchComponent>(toggle).selected, isFalse);
    expect(tester.widget<ToggleSwitchComponent>(toggle).onChanged, isNotNull);
    expect(requests.map((request) => (request.token, request.memoryCount)), [
      ("token", false),
      ("token", true),
      ("token", false),
    ]);
  });
}

class _AccountsClient extends Fake implements AccountsClient {
  final requests =
      <
        ({
          String token,
          bool memoryCount,
          Completer<AccountDetailsResponse> response,
        })
      >[];

  @override
  Future<AccountDetailsResponse> accountDetails({
    required String token,
    required bool memoryCount,
  }) {
    final response = Completer<AccountDetailsResponse>();
    requests.add((token: token, memoryCount: memoryCount, response: response));
    return response.future;
  }
}

class _PhotosRustApi extends Fake implements EntePhotosRustApi {
  _PhotosRustApi(this.client);

  final AccountsClient client;

  @override
  AccountsClient enteFrbLibAccountsCreateAccountsClient({
    required AccountsClientConfig config,
  }) => client;
}
