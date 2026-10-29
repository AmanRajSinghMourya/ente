import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'scene delivers each URL once without navigating a Flutter route',
    (tester) async {
      final link = Uri.parse('entelocker://scene-test/warm-link');
      final received = <Uri>[];
      final firstLink = Completer<void>();
      final subscription = AppLinks().uriLinkStream.listen((uri) {
        received.add(uri);
        if (!firstLink.isCompleted) firstLink.complete();
      });
      addTearDown(subscription.cancel);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Link delivery test'))),
      );

      expect(
        await launchUrl(link, mode: LaunchMode.externalApplication),
        isTrue,
      );

      await firstLink.future.timeout(const Duration(seconds: 10));
      await tester.pumpAndSettle();

      expect(received, [link]);
      expect(find.text('Link delivery test'), findsOneWidget);
    },
  );
}
