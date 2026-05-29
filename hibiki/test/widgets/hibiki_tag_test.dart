import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/hibiki_tag.dart';

import 'widget_test_helpers.dart';

void main() {
  group('HibikiTag', () {
    test('uses design token chip radius for every rounded tag surface', () {
      final String source =
          File('lib/src/utils/components/hibiki_tag.dart').readAsStringSync();

      expect(source, contains('tokens.radii.chipRadius'));
      expect(
          source, isNot(contains('BorderRadius.circular(tokens.radii.chip)')));
    });

    testWidgets('renders text label', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const HibikiTag(
          text: 'noun',
          backgroundColor: Colors.blue,
        ),
      ));

      expect(find.text('noun'), findsOneWidget);
    });

    testWidgets('renders icon when provided', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const HibikiTag(
          text: 'verb',
          backgroundColor: Colors.green,
          icon: Icons.label,
        ),
      ));

      expect(find.byIcon(Icons.label), findsOneWidget);
    });

    testWidgets('does not render icon when null', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const HibikiTag(
          text: 'adj',
          backgroundColor: Colors.orange,
        ),
      ));

      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('renders trailingText in separate container', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const HibikiTag(
          text: 'freq',
          backgroundColor: Colors.purple,
          trailingText: '★3',
        ),
      ));

      expect(find.text('freq'), findsOneWidget);
      expect(find.text('★3'), findsOneWidget);
    });

    testWidgets('InkWell is tappable when message is set', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const HibikiTag(
          text: 'click me',
          backgroundColor: Colors.red,
          message: 'Toast message',
        ),
      ));

      final inkWell = tester.widget<InkWell>(find.byType(InkWell));
      expect(inkWell.onTap, isNotNull);
    });

    testWidgets('InkWell has no onTap when message is null', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const HibikiTag(
          text: 'no action',
          backgroundColor: Colors.grey,
        ),
      ));

      final inkWell = tester.widget<InkWell>(find.byType(InkWell));
      expect(inkWell.onTap, isNull);
    });
  });
}
