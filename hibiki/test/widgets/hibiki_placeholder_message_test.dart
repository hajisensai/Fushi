import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/hibiki_placeholder_message.dart';

import 'widget_test_helpers.dart';

void main() {
  group('FushiPlaceholderMessage', () {
    testWidgets('renders icon and message text', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const FushiPlaceholderMessage(
          icon: Icons.error,
          message: 'Something went wrong',
        ),
      ));

      expect(find.byIcon(Icons.error), findsOneWidget);
      expect(find.text('Something went wrong'), findsOneWidget);
    });

    testWidgets('applies custom color to icon and text', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const FushiPlaceholderMessage(
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
        const FushiPlaceholderMessage(
          icon: Icons.check,
          message: 'Success',
          messageStyle: style,
        ),
      ));

      final Text text = tester.widget<Text>(find.text('Success'));
      expect(text.style?.fontSize, 24);
      expect(text.style?.color, Colors.green);
    });

    testWidgets('uses custom iconSize when provided', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const FushiPlaceholderMessage(
          icon: Icons.search,
          message: 'Search',
          iconSize: 18,
        ),
      ));

      final Icon icon = tester.widget<Icon>(find.byIcon(Icons.search));
      expect(icon.size, 18);
    });

    testWidgets('renders detail below the message, ellipsised to 3 lines',
        (tester) async {
      await tester.pumpWidget(buildTestApp(
        const FushiPlaceholderMessage(
          icon: Icons.error_outline,
          message: 'Something went wrong',
          detail: 'SqliteException(14): unable to open database file',
        ),
      ));

      final Text detail = tester.widget<Text>(
        find.text('SqliteException(14): unable to open database file'),
      );
      expect(detail.maxLines, 3);
      expect(detail.overflow, TextOverflow.ellipsis);
    });

    testWidgets('renders action widget and keeps it tappable', (tester) async {
      int taps = 0;
      await tester.pumpWidget(buildTestApp(
        FushiPlaceholderMessage(
          icon: Icons.error_outline,
          message: 'Something went wrong',
          action: FilledButton(
            onPressed: () => taps += 1,
            child: const Text('Retry'),
          ),
        ),
      ));

      await tester.tap(find.text('Retry'));
      expect(taps, 1);
    });
  });
}
