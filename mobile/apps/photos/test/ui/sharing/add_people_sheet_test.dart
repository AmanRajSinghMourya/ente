import "package:dio/dio.dart";
import "package:ente_components/ente_components.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:photos/core/configuration.dart";
import "package:photos/core/network/endpoint_config.dart";
import "package:photos/db/ml/dart_db.dart";
import "package:photos/ente_theme_data.dart";
import "package:photos/gateways/entity/entity_gateway.dart";
import "package:photos/models/api/collection/user.dart";
import "package:photos/models/collection/collection.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/account/user_service.dart";
import "package:photos/services/collections_service.dart";
import "package:photos/services/entity_service.dart";
import "package:photos/services/machine_learning/face_ml/person/person_service.dart";
import "package:photos/ui/sharing/add_people_sheet.dart";
import "package:shared_preferences/shared_preferences.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({
      Configuration.userIDKey: 1,
      Configuration.emailKey: "owner@example.com",
    });
    final preferences = await SharedPreferences.getInstance();
    try {
      await Configuration.instance.init(preferences);
    } on MissingPluginException {
      // This sheet only needs Configuration's preferences-backed identity.
    }
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          expect(options.path, "/users/public-key");
          handler.reject(
            DioException(
              requestOptions: options,
              response: Response(requestOptions: options, statusCode: 404),
              type: DioExceptionType.badResponse,
            ),
          );
        },
      ),
    );
    ServiceLocator.instance.enteDio = dio;
    ServiceLocator.instance.nonEnteDio = dio;
    ServiceLocator.instance.endpointConfig = EndpointConfig(preferences);
    await UserService.instance.init();
    PersonService.init(
      EntityService(preferences, EntityGateway(Dio())),
      DartMLDataDB.instance,
      preferences,
    );
  });

  tearDown(() {
    CollectionsService.instance.collectionIDToCollections.clear();
  });

  testWidgets("typing filters contacts and clearing restores the row", (
    tester,
  ) async {
    await _openSheet(tester, contactCount: 8);
    final list = find.byKey(const ValueKey("contact-suggestions-scroll"));
    await tester.drag(list, const Offset(-2000, 0));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), "  FRIEND1@EXAMPLE  ");
    await tester.pumpAndSettle();
    expect(_contact(1), findsOneWidget);
    expect(_contact(0), findsNothing);
    expect(_contact(7), findsNothing);
    expect(find.byTooltip("Previous"), findsNothing);
    expect(find.byTooltip("Next"), findsNothing);
    expect(_contact(1).hitTestable(), findsOneWidget);

    await tester.enterText(find.byType(TextField), "nobody@example.com");
    await tester.pumpAndSettle();
    expect(list, findsNothing);

    await tester.enterText(find.byType(TextField), "");
    await tester.pumpAndSettle();
    expect(_contact(0), findsOneWidget);
    expect(find.byTooltip("Previous"), findsNothing);
    expect(find.byTooltip("Next"), findsOneWidget);
  });

  testWidgets(
    "no account restores unselected contacts and a full-width button",
    (tester) async {
      await _openSheet(tester, contactCount: 4);
      await tester.tap(_contact(0));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), "nobody@example.com");
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(
        find.textContaining("No Ente account with this email."),
        findsOneWidget,
      );
      expect(_contact(0), findsNothing);
      expect(_contact(1), findsOneWidget);
      expect(_contact(2), findsOneWidget);
      final share = find.widgetWithText(ButtonComponent, "Share a link");
      expect(share, findsOneWidget);
      expect(
        tester.widget<ButtonComponent>(share).variant,
        ButtonComponentVariant.secondary,
      );
      final input = tester.getRect(find.byType(TextInputComponent));
      final button = tester.getRect(share);
      expect(button.width, input.width);
      expect(button.height, 52);
      expect(
        button.top,
        greaterThan(
          tester
              .getBottomLeft(find.text("No Ente account with this email."))
              .dy,
        ),
      );
      expect(button.bottom, lessThan(tester.getTopLeft(_contact(1)).dy));
      expect(
        tester
            .widget<ButtonComponent>(
              find.widgetWithText(ButtonComponent, "Continue"),
            )
            .isDisabled,
        isFalse,
      );

      await tester.enterText(find.byType(TextField), "friend2");
      await tester.pumpAndSettle();
      expect(share, findsNothing);
      expect(find.text("No Ente account with this email."), findsNothing);
      expect(_contact(1), findsNothing);
      expect(_contact(2), findsOneWidget);
    },
  );

  testWidgets("no-account actions remain usable above the keyboard", (
    tester,
  ) async {
    await _openSheet(
      tester,
      contactCount: 4,
      keyboardInset: 300,
      surfaceSize: const Size(360, 640),
      textScale: 1.3,
    );
    for (var index = 0; index < 3; index++) {
      await tester.ensureVisible(_contact(index));
      await tester.pumpAndSettle();
      await tester.tap(_contact(index));
      await tester.pumpAndSettle();
    }
    await tester.enterText(find.byType(TextField), "nobody@example.com");
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final continueButton = find.widgetWithText(ButtonComponent, "Continue");
    expect(continueButton.hitTestable(), findsOneWidget);
    final share = find.widgetWithText(ButtonComponent, "Share a link");
    await tester.ensureVisible(share);
    await tester.pumpAndSettle();
    expect(share.hitTestable(), findsOneWidget);
    await tester.ensureVisible(_contact(3));
    await tester.pumpAndSettle();
    expect(_contact(3).hitTestable(), findsOneWidget);
  });

  testWidgets("chevrons follow swipes and button taps at both ends", (
    tester,
  ) async {
    await _openSheet(tester, contactCount: 8);
    final list = find.byKey(const ValueKey("contact-suggestions-scroll"));
    expect(find.byTooltip("Previous"), findsNothing);
    expect(find.byTooltip("Next"), findsOneWidget);

    await tester.tap(find.byTooltip("Next"));
    await tester.pumpAndSettle();
    expect(find.byTooltip("Previous"), findsOneWidget);
    expect(find.byTooltip("Next"), findsOneWidget);

    await tester.drag(list, const Offset(-2000, 0));
    await tester.pumpAndSettle();
    expect(find.byTooltip("Previous"), findsOneWidget);
    expect(find.byTooltip("Next"), findsNothing);

    await tester.tap(find.byTooltip("Previous"));
    await tester.pumpAndSettle();
    expect(find.byTooltip("Previous"), findsOneWidget);
    expect(find.byTooltip("Next"), findsOneWidget);

    await tester.drag(list, const Offset(2000, 0));
    await tester.pumpAndSettle();
    expect(find.byTooltip("Previous"), findsNothing);
    expect(find.byTooltip("Next"), findsOneWidget);
  });

  testWidgets("both chevrons are hidden when all contacts fit", (tester) async {
    await _openSheet(tester, contactCount: 2);
    expect(find.byTooltip("Previous"), findsNothing);
    expect(find.byTooltip("Next"), findsNothing);
  });

  testWidgets("selecting a contact updates whether the list can scroll", (
    tester,
  ) async {
    await _openSheet(tester, contactCount: 4);
    expect(find.byTooltip("Next"), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey("contact-suggestion-friend0@example.com")),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip("Previous"), findsNothing);
    expect(find.byTooltip("Next"), findsNothing);
  });

  testWidgets("a contact can be reselected while its previous chip is fading", (
    tester,
  ) async {
    await _openSheet(tester, contactCount: 2);
    final contact = find.byKey(
      const ValueKey("contact-suggestion-friend0@example.com"),
    );
    await tester.tap(contact);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey("remove-friend0@example.com")));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(contact, findsOneWidget);
    await tester.tap(contact);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey("selected-person-chip-friend0@example.com")),
      findsOneWidget,
    );
    expect(contact, findsNothing);
  });

  testWidgets("repeated removal cannot select the contact again", (
    tester,
  ) async {
    await _openSheet(tester, contactCount: 2);
    final contact = find.byKey(
      const ValueKey("contact-suggestion-friend0@example.com"),
    );
    await tester.tap(contact);
    await tester.pumpAndSettle();
    final remove = find.byKey(const ValueKey("remove-friend0@example.com"));
    await tester.tap(remove);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(contact, findsOneWidget);
    expect(
      find.byKey(const ValueKey("selected-person-chip-friend0@example.com")),
      findsNothing,
    );
    expect(
      tester.widget<ButtonComponent>(find.byType(ButtonComponent)).isDisabled,
      isTrue,
    );
  });

  testWidgets("resizing updates chevrons without a scroll gesture", (
    tester,
  ) async {
    await _openSheet(tester, contactCount: 4);
    expect(find.byTooltip("Next"), findsOneWidget);
    await tester.binding.setSurfaceSize(const Size(700, 800));
    await tester.pumpAndSettle();
    expect(find.byTooltip("Previous"), findsNothing);
    expect(find.byTooltip("Next"), findsNothing);
    await tester.binding.setSurfaceSize(const Size(360, 800));
    await tester.pumpAndSettle();
    expect(find.byTooltip("Previous"), findsNothing);
    expect(find.byTooltip("Next"), findsOneWidget);
  });
}

Finder _contact(int index) =>
    find.byKey(ValueKey("contact-suggestion-friend$index@example.com"));

Future<void> _openSheet(
  WidgetTester tester, {
  required int contactCount,
  double keyboardInset = 0,
  Size surfaceSize = const Size(360, 800),
  double textScale = 1,
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final album = _album(1);
  CollectionsService.instance.collectionIDToCollections[2] = _album(2)
    ..sharees.addAll([
      for (var i = 0; i < contactCount; i++)
        User(id: i + 10, email: "friend$i@example.com"),
    ]);
  await tester.pumpWidget(
    MaterialApp(
      theme: lightThemeData,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          viewInsets: EdgeInsets.only(bottom: keyboardInset),
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      localizationsDelegates: StringsLocalizations.localizationsDelegates,
      supportedLocales: StringsLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAddPeopleSheet(context, [album]),
            child: const Text("Share album"),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text("Share album"));
  await tester.pumpAndSettle();
}

Collection _album(int id) => Collection(
  id,
  User(id: 1, email: "owner@example.com"),
  "",
  null,
  "Album $id",
  null,
  null,
  CollectionType.album,
  CollectionAttributes(),
  [],
  [],
  id,
);
