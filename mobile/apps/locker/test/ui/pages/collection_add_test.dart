import 'dart:async';
import 'dart:io';

import 'package:ente_components/ente_components.dart';
import 'package:ente_events/event_bus.dart';
import 'package:ente_network/network.dart';
import 'package:ente_sharing/models/user.dart';
import 'package:ente_strings/ente_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:locker/events/collections_updated_event.dart';
import 'package:locker/services/collections/collections_service.dart';
import 'package:locker/services/collections/models/collection.dart';
import 'package:locker/services/configuration.dart';
import 'package:locker/services/db/locker_db.dart';
import 'package:locker/services/feature_flag_service.dart';
import 'package:locker/ui/pages/collection_page.dart';
import 'package:locker/ui/pages/personal_note_page.dart';
import 'package:locker/ui/pages/save_page.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../../test_utils/configuration_test_util.dart';

void main() {
  const databaseChannel = MethodChannel('com.tekartik.sqflite');
  late Directory testRoot;
  late SharedPreferences preferences;
  Completer<List<Map<String, Object?>>>? pendingFiles;

  Collection collection({
    CollectionType type = CollectionType.folder,
    int owner = 1,
  }) => Collection(
    42,
    User(id: owner, email: 'owner@example.com'),
    '',
    null,
    'Documents',
    null,
    null,
    type,
    CollectionAttributes(),
    const [],
    const [],
    0,
  );

  setUpAll(() {
    databaseFactory = databaseFactorySqflitePlugin;
  });

  setUp(() async {
    testRoot = await setupLockerConfigurationForTest('collection_add');
    await Configuration.instance.setUserID(1);
    PackageInfo.setMockInitialValues(
      appName: 'Locker',
      packageName: 'io.ente.locker',
      version: '1.0.11',
      buildNumber: '182',
      buildSignature: '',
    );
    await Network.instance.init(Configuration.instance);
    preferences = await SharedPreferences.getInstance();
    await preferences.setString('remote_flags', '{}');
    pendingFiles = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(databaseChannel, (call) async {
          switch (call.method) {
            case 'openDatabase':
              return {'id': 1};
            case 'query':
              final sql = (call.arguments as Map)['sql'] as String;
              if (sql.contains('PRAGMA user_version')) {
                return [
                  {'user_version': 2},
                ];
              }
              if (sql.contains('SELECT f.*') && pendingFiles != null) {
                return pendingFiles!.future;
              }
              return <Map<String, Object?>>[];
            default:
              return null;
          }
        });
    await LockerDB.instance.init();
    await CollectionService.instance.init(preferences);
  });

  tearDown(() async {
    await LockerDB.instance.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(databaseChannel, null);
    clearLockerConfigurationTestHandlers();
    await testRoot.delete(recursive: true);
  });

  Future<void> showPage(
    WidgetTester tester,
    Collection target, {
    bool pushRoute = false,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FeatureFlagService.instance.init(preferences);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: StringsLocalizations.localizationsDelegates,
        supportedLocales: const [Locale('en')],
        home: pushRoute
            ? Builder(
                builder: (context) => TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => CollectionPage(collection: target),
                    ),
                  ),
                  child: const Text('open collection'),
                ),
              )
            : CollectionPage(collection: target),
      ),
    );
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  }

  testWidgets(
    'empty owned collection exposes both actions with a fixed destination',
    (tester) async {
      await showPage(tester, collection());
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(ButtonComponent, 'Add documents'),
        findsOneWidget,
      );
      expect(find.byType(FABComponent), findsOneWidget);
      for (final action in [
        find.widgetWithText(ButtonComponent, 'Add documents'),
        find.byType(FABComponent),
      ]) {
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<SaveBottomSheet>(find.byType(SaveBottomSheet))
              .fixedCollection
              ?.id,
          42,
        );
        tester.state<NavigatorState>(find.byType(Navigator)).pop();
        await tester.pumpAndSettle();
      }
      await finish(tester);
    },
  );

  testWidgets('loading does not expose the empty-collection actions', (
    tester,
  ) async {
    pendingFiles = Completer<List<Map<String, Object?>>>();
    await showPage(tester, collection());
    expect(find.byType(LoadingComponent), findsOneWidget);
    expect(find.byType(FABComponent), findsNothing);
    expect(find.text('Add documents'), findsNothing);
    pendingFiles!.complete([]);
    await tester.pumpAndSettle();
    expect(find.byType(FABComponent), findsOneWidget);
    await finish(tester);
  });

  testWidgets('failed initial loading offers retry instead of add actions', (
    tester,
  ) async {
    pendingFiles = Completer<List<Map<String, Object?>>>();
    await showPage(tester, collection());
    pendingFiles!.completeError(StateError('file query failed'));
    await tester.pumpAndSettle();
    expect(find.byType(LoadingComponent), findsNothing);
    expect(find.byType(FABComponent), findsNothing);
    expect(find.text('Add documents'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    pendingFiles = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byType(FABComponent), findsOneWidget);
    await finish(tester);
  });

  testWidgets('collection deletion preserves the open form until cancellation', (
    tester,
  ) async {
    await showPage(tester, collection(), pushRoute: true);
    await tester.tap(find.text('open collection'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FABComponent));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Note'));
    await tester.pumpAndSettle();
    Bus.instance.fire(CollectionsUpdatedEvent('collection_deleted'));
    await tester.pumpAndSettle();
    expect(find.byType(PersonalNotePage), findsOneWidget);
    expect(find.byType(CollectionPage), findsNothing);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.text('open collection'), findsOneWidget);
    expect(find.byType(SaveBottomSheet), findsNothing);
    await finish(tester);
  });

  testWidgets('disabling the internal flag hides both actions', (tester) async {
    await preferences.setBool('ls.internal_user_disabled', true);
    await showPage(tester, collection());
    await tester.pumpAndSettle();
    expect(find.byType(FABComponent), findsNothing);
    expect(find.text('Add documents'), findsNothing);
    await finish(tester);
  });

  testWidgets('disabled internal flag retains the empty state while loading', (
    tester,
  ) async {
    await preferences.setBool('ls.internal_user_disabled', true);
    pendingFiles = Completer<List<Map<String, Object?>>>();
    await showPage(tester, collection());
    expect(find.byType(LoadingComponent), findsNothing);
    expect(find.text('Nothing to see here'), findsOneWidget);
    expect(find.byType(FABComponent), findsNothing);
    pendingFiles!.complete([]);
    await tester.pumpAndSettle();
    await finish(tester);
  });

  final excluded = [
    collection(type: CollectionType.favorites),
    collection(type: CollectionType.uncategorized),
    collection(owner: 2),
    collection()..mMdEncodedJson = '{"subType":2}',
    collection()..mMdEncodedJson = '{"subType":1}',
    collection()
      ..mMdVersion = 1
      ..mMdEncodedJson = '{"visibility":2}',
  ];
  for (var index = 0; index < excluded.length; index++) {
    testWidgets('special or incoming collection $index has no add actions', (
      tester,
    ) async {
      await showPage(tester, excluded[index]);
      await tester.pumpAndSettle();
      expect(find.byType(FABComponent), findsNothing);
      expect(find.text('Add documents'), findsNothing);
      await finish(tester);
    });
  }
}
