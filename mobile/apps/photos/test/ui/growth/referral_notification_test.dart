import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:ente_strings/ente_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/ente_theme_data.dart';
import 'package:photos/service_locator.dart';
import 'package:photos/services/account/user_service.dart';
import 'package:photos/services/app_navigation_service.dart';
import 'package:photos/ui/growth/referral_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({
      UserService.keyUserDetails: jsonEncode({
        'email': 'referrer@example.com',
        'usage': 0,
        'subscription': {
          'productID': 'free',
          'storage': 0,
          'originalTransactionID': '',
          'paymentProvider': '',
          'expiryTime': 0,
          'price': '',
          'period': '',
        },
      }),
    });
    final preferences = await SharedPreferences.getInstance();
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            handler.resolve(
              Response(
                requestOptions: request,
                data: {
                  'planInfo': {
                    'isEnabled': false,
                    'planType': 'test',
                    'storageInGB': 10,
                    'maxClaimableStorageInGB': 10,
                  },
                  'code': 'REFER1',
                  'enableApplyCode': false,
                  'isFamilyMember': false,
                  'hasAppliedCode': true,
                  'claimedStorage': 0,
                },
              ),
            );
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
    } catch (_) {}
    await UserService.instance.init();
  });

  testWidgets('referral notification opens over an existing route', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: AppNavigationService.instance.navigatorKey,
        theme: lightThemeData,
        localizationsDelegates: StringsLocalizations.localizationsDelegates,
        supportedLocales: StringsLocalizations.supportedLocales,
        home: const Scaffold(body: Text('Home')),
      ),
    );
    unawaited(
      AppNavigationService.instance.pushPage(
        const Scaffold(body: Text('Settings')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);

    unawaited(AppNavigationService.instance.pushPage(const ReferralScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Get free storage'), findsOneWidget);
    AppNavigationService.instance.navigator!.pop();
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
  });
}
