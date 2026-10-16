import 'package:ente_strings/ente_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos/ente_theme_data.dart';
import 'package:photos/gateways/collections/models/public_url.dart';
import 'package:photos/models/api/collection/user.dart';
import 'package:photos/models/button_result.dart';
import 'package:photos/models/collection/collection.dart';
import 'package:photos/ui/components/buttons/button_widget.dart';
import 'package:photos/ui/sharing/manage_links_widget.dart';

void main() {
  testWidgets('removing a quick link opened directly preserves Home', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final collection = Collection(
      41,
      User(id: 1, email: 'owner@example.com'),
      'key',
      null,
      'Quick link',
      null,
      null,
      CollectionType.album,
      CollectionAttributes(),
      [],
      [
        PublicURL(
          url: 'https://albums.example.com/test',
          deviceLimit: 0,
          validTill: 1,
        ),
      ],
      1,
    )..mMdEncodedJson = '{"subType":2}';
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: darkThemeData,
        localizationsDelegates: StringsLocalizations.localizationsDelegates,
        supportedLocales: StringsLocalizations.supportedLocales,
        home: const Scaffold(body: Text('Home')),
      ),
    );
    await tester.pumpAndSettle();
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => ManageSharedLinkWidget(
          collection: collection,
          popCollectionOnRemove: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Remove link'), 400);
    await tester.tap(find.text('Remove link'));
    await tester.pumpAndSettle();
    navigator.currentState!.pop(ButtonResult(ButtonAction.first));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(navigator.currentState!.canPop(), isFalse);
  });
}
