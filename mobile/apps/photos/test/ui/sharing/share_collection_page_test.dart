import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:photos/core/configuration.dart";
import "package:photos/ente_theme_data.dart";
import "package:photos/gateways/collections/models/public_url.dart";
import "package:photos/models/collection/collection.dart";
import "package:photos/ui/sharing/share_collection_page.dart";
import "package:shared_preferences/shared_preferences.dart";

import "library_sharing_test_helpers.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({Configuration.userIDKey: 1});
    try {
      await Configuration.instance.init(await SharedPreferences.getInstance());
    } on MissingPluginException {
      // The page only needs Configuration's preferences-backed identity.
    }
  });

  testWidgets("centers the empty illustration and message above Add person", (
    tester,
  ) async {
    await _pumpPage(tester, librarySharingTestAlbum(1));
    final illustration = find.image(
      const AssetImage("assets/empty_album_sharing.png"),
    );
    final message = find.text(
      "You have not shared\nthis album with anyone yet.",
    );
    expect(illustration, findsOneWidget);
    expect(message, findsOneWidget);
    expect(tester.getSize(illustration), const Size(76, 52));
    expect(tester.getCenter(illustration).dx, 187.5);
    expect(tester.getCenter(message).dx, 187.5);
    expect(
      tester.getTopLeft(message).dy - tester.getBottomLeft(illustration).dy,
      12,
    );
    final text = tester.widget<Text>(message);
    expect(text.textAlign, TextAlign.center);
    expect(text.style!.fontFamily, "packages/ente_components/Inter");
    expect(text.style!.fontSize, 14);
    expect(text.style!.fontWeight, FontWeight.w500);
    expect(text.style!.height, 20 / 14);
    expect(find.text("Add person"), findsOneWidget);
  });

  testWidgets("shows the empty message even when a public link exists", (
    tester,
  ) async {
    final album = librarySharingTestAlbum(1)
      ..publicURLs.add(
        PublicURL(url: "https://example.com", deviceLimit: 0, validTill: 1),
      );
    await _pumpPage(tester, album);
    expect(
      find.image(const AssetImage("assets/empty_album_sharing.png")),
      findsOneWidget,
    );
    expect(find.textContaining("You have not shared"), findsOneWidget);
  });

  testWidgets("empty content grows for larger text without overflow", (
    tester,
  ) async {
    await _pumpPage(tester, librarySharingTestAlbum(1), textScale: 2);
    expect(find.textContaining("You have not shared"), findsOneWidget);
    expect(find.text("Add person"), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final scale in [1.0, 2.0, 3.0]) {
    testWidgets("loads the ${scale.toInt()}x illustration variant", (
      tester,
    ) async {
      final key = await const AssetImage(
        "assets/empty_album_sharing.png",
      ).obtainKey(ImageConfiguration(devicePixelRatio: scale));
      expect(
        key.name,
        scale == 1
            ? "assets/empty_album_sharing.png"
            : "assets/${scale.toStringAsFixed(1)}x/empty_album_sharing.png",
      );
      expect(key.scale, scale);
    });
  }
}

Future<void> _pumpPage(
  WidgetTester tester,
  Collection album, {
  double textScale = 1,
}) async {
  await tester.binding.setSurfaceSize(const Size(375, 812));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: lightThemeData,
      localizationsDelegates: StringsLocalizations.localizationsDelegates,
      supportedLocales: StringsLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: ShareCollectionPage(album),
    ),
  );
  await tester.pumpAndSettle();
}
