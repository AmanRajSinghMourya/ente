import 'package:ente_components/ente_components.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:photos/ui/viewer/gallery/gallery_app_bar_actions.dart';

void main() {
  testWidgets(
    'open gallery menu icons follow the theme without rebuilding options',
    (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      var optionBuilds = 0;
      final warning = ComponentTheme.colorsForApp(
        ComponentApp.photos,
        brightness: Brightness.light,
      ).warning;

      await tester.pumpWidget(
        MaterialApp(
          theme: ComponentTheme.lightTheme(),
          darkTheme: ComponentTheme.darkTheme(),
          home: Scaffold(
            body: galleryAppBarPopupMenuAction<String>(
              icon: const HugeIcon(icon: HugeIcons.strokeRoundedMoreVertical),
              tooltip: 'More',
              optionsBuilder: () {
                optionBuilds++;
                return [
                  EntePopupMenuOption(
                    value: 'edit',
                    label: 'Edit',
                    leadingWidget: galleryAppBarMenuIcon(
                      HugeIcons.strokeRoundedEdit03,
                    ),
                  ),
                  EntePopupMenuOption(
                    value: 'delete',
                    label: 'Delete',
                    labelColor: warning,
                    leadingWidget: galleryAppBarMenuIcon(
                      HugeIcons.strokeRoundedDelete01,
                      color: warning,
                    ),
                  ),
                ];
              },
              onSelected: (_) {},
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();

      for (final brightness in [
        Brightness.light,
        Brightness.dark,
        Brightness.light,
      ]) {
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        await tester.pumpAndSettle();
        final colors = ComponentTheme.colorsForApp(
          ComponentApp.photos,
          brightness: brightness,
        );
        for (final (label, expectedColor) in [
          ('Edit', colors.textLight),
          ('Delete', colors.warning),
        ]) {
          final iconFinder = find.descendant(
            of: find.ancestor(
              of: find.text(label),
              matching: find.byType(PopupMenuItem<String>),
            ),
            matching: find.byType(HugeIcon),
          );
          final icon = tester.widget<HugeIcon>(iconFinder);
          expect(
            icon.color ?? IconTheme.of(tester.element(iconFinder)).color,
            expectedColor,
          );
          expect(icon.size, IconSizes.small);
        }
        expect(optionBuilds, 1);
        expect(tester.takeException(), isNull);
      }
    },
  );
}
