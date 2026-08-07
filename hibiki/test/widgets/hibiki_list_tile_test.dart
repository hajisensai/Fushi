import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/hibiki_list_tile.dart';

import 'widget_test_helpers.dart';

void main() {
  group('FushiListTile', () {
    testWidgets('renders title, subtitle and icon', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const FushiListTile(
          title: 'My Dictionary',
          subtitle: 'JMDict English',
          icon: Icons.book,
          selected: false,
        ),
      ));

      expect(find.text('My Dictionary'), findsOneWidget);
      expect(find.text('JMDict English'), findsOneWidget);
      expect(find.byIcon(Icons.book), findsOneWidget);
    });

    testWidgets('trailing only shows when selected', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const FushiListTile(
          title: 'Item',
          subtitle: 'Sub',
          icon: Icons.star,
          selected: false,
          trailing: Icon(Icons.check),
        ),
      ));

      expect(find.byIcon(Icons.check), findsNothing);

      await tester.pumpWidget(buildTestApp(
        const FushiListTile(
          title: 'Item',
          subtitle: 'Sub',
          icon: Icons.star,
          selected: true,
          trailing: Icon(Icons.check),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('calls onTap callback', (tester) async {
      bool tapped = false;
      await tester.pumpWidget(buildTestApp(
        FushiListTile(
          title: 'Tap Me',
          subtitle: 'Sub',
          icon: Icons.touch_app,
          selected: false,
          onTap: () => tapped = true,
        ),
      ));

      await tester.tap(find.text('Tap Me'));
      expect(tapped, isTrue);
    });
  });
}
