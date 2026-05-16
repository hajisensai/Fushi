import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/jidoujisho_placeholder_message.dart';

import 'widget_test_helpers.dart';

void main() {
  group('JidoujishoPlaceholderMessage', () {
    testWidgets('renders icon and message text', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const JidoujishoPlaceholderMessage(
          icon: Icons.error,
          message: 'Something went wrong',
        ),
      ));

      expect(find.byIcon(Icons.error), findsOneWidget);
      expect(find.text('Something went wrong'), findsOneWidget);
    });

    testWidgets('applies custom color to icon and text', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const JidoujishoPlaceholderMessage(
          icon: Icons.info,
          message: 'Info message',
          color: Colors.blue,
        ),
      ));

      final Icon icon = tester.widget<Icon>(find.byIcon(Icons.info));
      expect(icon.color, Colors.blue);
    });

    testWidgets('uses custom messageStyle when provided', (tester) async {
      const style = TextStyle(fontSize: 24, color: Colors.green);
      await tester.pumpWidget(buildTestApp(
        const JidoujishoPlaceholderMessage(
          icon: Icons.check,
          message: 'Success',
          messageStyle: style,
        ),
      ));

      final Text text = tester.widget<Text>(find.text('Success'));
      expect(text.style?.fontSize, 24);
      expect(text.style?.color, Colors.green);
    });
  });
}
