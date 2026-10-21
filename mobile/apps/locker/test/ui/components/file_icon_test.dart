import 'package:ente_components/ente_components.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:locker/utils/file_icon_utils.dart';

void main() {
  for (final name in ['photo.jpeg', 'photo.JPEG', 'photo.jpg']) {
    testWidgets('$name shows the image icon', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ComponentTheme.lightTheme(app: ComponentApp.locker),
          home: Builder(
            builder: (context) => FileIconUtils.getFileIcon(
              context,
              name,
              backgroundColor: Colors.white,
            ),
          ),
        ),
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is HugeIcon &&
              widget.icon == HugeIcons.strokeRoundedImage01,
        ),
        findsOneWidget,
      );
    });
  }
}
