import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/Hibiki_tag.dart';

import 'golden_test_helpers.dart';

void main() {
  group('HibikiTag golden', () {
    testWidgets('basic tag', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const HibikiTag(text: 'noun', backgroundColor: Colors.blue),
        size: const Size(200, 60),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/tag_basic.png'),
      );
    });

    testWidgets('tag with icon', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const HibikiTag(
          text: 'verb',
          backgroundColor: Colors.green,
          icon: Icons.label,
        ),
        size: const Size(200, 60),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/tag_with_icon.png'),
      );
    });

    testWidgets('tag with trailing text', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const HibikiTag(
          text: 'freq',
          backgroundColor: Colors.purple,
          trailingText: '★3',
        ),
        size: const Size(250, 60),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/tag_trailing.png'),
      );
    });

    testWidgets('tag dark theme', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const HibikiTag(
          text: 'dark',
          backgroundColor: Colors.teal,
          icon: Icons.dark_mode,
        ),
        theme: ThemeData.dark(useMaterial3: true),
        size: const Size(200, 60),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/tag_dark.png'),
      );
    });

    testWidgets('tag custom foreground', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const HibikiTag(
          text: 'custom',
          backgroundColor: Color(0xFF263238),
          foregroundColor: Colors.amber,
          icon: Icons.star,
        ),
        size: const Size(200, 60),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/tag_custom_color.png'),
      );
    });
  });
}
