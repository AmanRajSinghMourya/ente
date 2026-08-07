import 'dart:math' as math;

import 'package:ente_components/components/buttons/dynamic_fab.dart'
    show NoScalingAnimation;
import 'package:ente_components/ente_components.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const lightSurface = Color(0xFF123456);
  const darkSurface = Color(0xFF654321);

  testWidgets('shows a full-width button when the keyboard is closed', (
    tester,
  ) async {
    var tapCount = 0;

    await tester.pumpWidget(
      _wrap(
        DynamicFAB(
          isKeypadOpen: false,
          isFormValid: true,
          buttonText: 'Continue',
          onPressedFunction: () => tapCount += 1,
        ),
      ),
    );

    expect(find.byType(ButtonComponent), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(tester.getSize(find.byType(ButtonComponent)).width, 768);

    await tester.tap(find.text('Continue'));
    await tester.pump();

    expect(tapCount, 1);
  });

  testWidgets('disables the full-width button for an invalid form', (
    tester,
  ) async {
    var tapCount = 0;

    await tester.pumpWidget(
      _wrap(
        DynamicFAB(
          isKeypadOpen: false,
          isFormValid: false,
          buttonText: 'Continue',
          onPressedFunction: () => tapCount += 1,
        ),
      ),
    );

    final button = tester.widget<ButtonComponent>(find.byType(ButtonComponent));
    expect(button.isDisabled, isTrue);

    await tester.tap(find.text('Continue'));
    await tester.pump();

    expect(tapCount, 0);
  });

  testWidgets('shows a circular FAB and submits a valid form', (tester) async {
    var tapCount = 0;

    await tester.pumpWidget(
      _wrap(
        DynamicFAB(
          isKeypadOpen: true,
          isFormValid: true,
          buttonText: 'Continue',
          onPressedFunction: () => tapCount += 1,
        ),
        surfaceColor: lightSurface,
      ),
    );

    expect(find.byType(ButtonComponent), findsNothing);
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(_chevronRotation(tester), closeTo(0, 1e-10));

    final fab = tester.widget<FloatingActionButton>(
      find.byType(FloatingActionButton),
    );
    expect(fab.backgroundColor, colorTokensLight.dynamicFabBackground);
    expect(fab.foregroundColor, colorTokensLight.specialWhite);
    expect(_shadowColor(tester), lightSurface);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();

    expect(tapCount, 1);
  });

  testWidgets('uses dark component colors for the FAB and backdrop', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const DynamicFAB(
          isKeypadOpen: true,
          isFormValid: true,
          buttonText: 'Continue',
        ),
        brightness: Brightness.dark,
        surfaceColor: darkSurface,
      ),
    );

    final fab = tester.widget<FloatingActionButton>(
      find.byType(FloatingActionButton),
    );
    expect(fab.backgroundColor, colorTokensDark.dynamicFabBackground);
    expect(fab.foregroundColor, colorTokensDark.specialWhite);
    expect(_shadowColor(tester), darkSurface);
  });

  testWidgets('rotates the chevron and dismisses focus for an invalid form', (
    tester,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      _wrap(
        Column(
          children: [
            TextField(focusNode: focusNode),
            const DynamicFAB(
              isKeypadOpen: true,
              isFormValid: false,
              buttonText: 'Continue',
            ),
          ],
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);
    expect(_chevronRotation(tester), closeTo(math.pi / 2, 1e-10));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();

    expect(focusNode.hasFocus, isFalse);
  });

  test('NoScalingAnimation preserves offset, scale, and rotation', () {
    final animator = NoScalingAnimation();
    const parent = AlwaysStoppedAnimation<double>(0.5);
    const end = Offset(12, 34);

    expect(animator.getOffset(end: end), end);
    expect(animator.getScaleAnimation(parent: parent).value, 1);
    expect(animator.getRotationAnimation(parent: parent).value, 1);
  });
}

Widget _wrap(
  Widget child, {
  Brightness brightness = Brightness.light,
  Color? surfaceColor,
}) {
  final theme = ComponentTheme.themeForApp(
    ComponentApp.auth,
    brightness: brightness,
  );
  return MaterialApp(
    theme: theme.copyWith(
      colorScheme: theme.colorScheme.copyWith(surface: surfaceColor),
    ),
    home: Scaffold(body: child),
  );
}

Color _shadowColor(WidgetTester tester) {
  final container = tester.widget<Container>(find.byType(Container).first);
  final decoration = container.decoration! as BoxDecoration;
  return decoration.boxShadow!.single.color;
}

double _chevronRotation(WidgetTester tester) {
  final transform = tester.widget<Transform>(
    find.byWidgetPredicate(
      (widget) =>
          widget is Transform &&
          widget.child is Icon &&
          (widget.child! as Icon).icon == Icons.chevron_right,
    ),
  );
  return math.atan2(
    transform.transform.entry(1, 0),
    transform.transform.entry(0, 0),
  );
}
