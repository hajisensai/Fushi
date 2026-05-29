import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/hibiki_marquee.dart';

import 'golden_test_helpers.dart';

void main() {
  group('HibikiMarquee golden', () {
    testWidgets('short text fits without scrolling', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const HibikiMarquee(
          text: 'Short',
          style: TextStyle(fontSize: 16),
        ),
        size: const Size(300, 40),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/marquee_short.png'),
      );
    });

    testWidgets('Japanese text fits at adequate width', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const HibikiMarquee(
          text: '吾輩は猫',
          style: TextStyle(fontSize: 16),
        ),
        size: const Size(300, 40),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/marquee_japanese_short.png'),
      );
    });

    testWidgets('with custom style non-overflow', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const HibikiMarquee(
          text: 'Styled',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.deepPurple,
          ),
        ),
        size: const Size(300, 50),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/marquee_styled.png'),
      );
    });

    testWidgets('dark theme non-overflow', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const HibikiMarquee(
          text: 'Dark mode',
          style: TextStyle(fontSize: 16, color: Colors.white),
        ),
        theme: ThemeData.dark(useMaterial3: true),
        size: const Size(300, 40),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/marquee_dark.png'),
      );
    });
  });
}
