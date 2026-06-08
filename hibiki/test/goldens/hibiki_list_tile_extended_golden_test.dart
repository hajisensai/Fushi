@Tags(<String>['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/hibiki_list_tile.dart';

import 'golden_test_helpers.dart';

void main() {
  group('HibikiListTile extended golden', () {
    testWidgets('multi-word title and subtitle', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const HibikiListTile(
          title: '明鏡国語辞典 第三版',
          subtitle: 'JA-JA monolingual',
          icon: Icons.menu_book,
          selected: false,
        ),
        size: const Size(400, 80),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/list_tile_long_text.png'),
      );
    });

    testWidgets('narrow width', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const HibikiListTile(
          title: 'Dict',
          subtitle: 'JA',
          icon: Icons.book,
          selected: true,
        ),
        size: const Size(150, 80),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/list_tile_narrow.png'),
      );
    });

    testWidgets('wide layout', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const HibikiListTile(
          title: '明鏡国語辞典',
          subtitle: 'JA-JA 国語辞典',
          icon: Icons.translate,
          selected: true,
          trailing: Icon(Icons.check_circle, color: Colors.green),
        ),
        size: const Size(600, 80),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/list_tile_wide.png'),
      );
    });

    testWidgets('custom seed color theme selected', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const HibikiListTile(
          title: 'Seeded theme',
          subtitle: 'Material You color',
          icon: Icons.palette,
          selected: true,
        ),
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: Colors.teal,
        ),
        size: const Size(400, 80),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/list_tile_seed_theme.png'),
      );
    });

    testWidgets('high contrast dark theme', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const HibikiListTile(
          title: 'High Contrast',
          subtitle: 'Dark variant',
          icon: Icons.contrast,
          selected: true,
          foregroundColor: Colors.white,
        ),
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.red,
            brightness: Brightness.dark,
          ),
        ),
        size: const Size(400, 80),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/list_tile_high_contrast.png'),
      );
    });
  });
}
