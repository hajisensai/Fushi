import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/Hibiki_tag.dart';

import 'golden_test_helpers.dart';

void main() {
  group('HibikiTag overflow golden', () {
    testWidgets('very long text truncates with ellipsis', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const HibikiTag(
          text: 'This is an extremely long tag label that should overflow',
          backgroundColor: Colors.indigo,
        ),
        size: const Size(150, 60),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/tag_overflow_long_text.png'),
      );
    });

    testWidgets('icon + long text + trailing in tight space', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const HibikiTag(
          text: 'Very long tag content here',
          backgroundColor: Colors.deepPurple,
          icon: Icons.star,
          trailingText: '★★★★★',
        ),
        size: const Size(200, 60),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/tag_overflow_all_parts.png'),
      );
    });

    testWidgets('minimal width still renders', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const HibikiTag(
          text: 'noun',
          backgroundColor: Colors.orange,
        ),
        size: const Size(60, 40),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/tag_minimal_width.png'),
      );
    });

    testWidgets('large size renders cleanly', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const HibikiTag(
          text: 'adjective',
          backgroundColor: Colors.teal,
          icon: Icons.label,
          trailingText: '42',
        ),
        size: const Size(600, 100),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/tag_large_size.png'),
      );
    });

    testWidgets('Japanese text renders correctly', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const HibikiTag(
          text: '名詞・形容動詞',
          backgroundColor: Color(0xFF1B5E20),
          foregroundColor: Colors.white,
        ),
        size: const Size(250, 60),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/tag_japanese_text.png'),
      );
    });

    testWidgets('custom seed color theme', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const HibikiTag(
          text: 'seeded',
          backgroundColor: Colors.blue,
          icon: Icons.palette,
        ),
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: Colors.deepOrange,
        ),
        size: const Size(200, 60),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/tag_seed_theme.png'),
      );
    });
  });
}
