import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/hibiki_list_tile.dart';

import 'golden_test_helpers.dart';

void main() {
  group('HibikiListTile golden', () {
    testWidgets('unselected', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const HibikiListTile(
          title: 'Dictionary A',
          subtitle: 'JA-JA monolingual',
          icon: Icons.menu_book,
          selected: false,
        ),
        size: const Size(400, 80),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/list_tile_unselected.png'),
      );
    });

    testWidgets('selected', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const HibikiListTile(
          title: 'Dictionary B',
          subtitle: 'JA-EN bilingual',
          icon: Icons.translate,
          selected: true,
        ),
        size: const Size(400, 80),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/list_tile_selected.png'),
      );
    });

    testWidgets('selected with trailing', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const HibikiListTile(
          title: 'Active dict',
          subtitle: 'With reorder handle',
          icon: Icons.drag_handle,
          selected: true,
          trailing: Icon(Icons.reorder, size: 20),
        ),
        size: const Size(400, 80),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/list_tile_trailing.png'),
      );
    });

    testWidgets('custom foreground', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const HibikiListTile(
          title: 'Disabled',
          subtitle: 'Greyed out',
          icon: Icons.block,
          selected: false,
          foregroundColor: Colors.grey,
        ),
        size: const Size(400, 80),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/list_tile_custom_fg.png'),
      );
    });

    testWidgets('dark theme', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const HibikiListTile(
          title: 'Dark dict',
          subtitle: 'Dark theme variant',
          icon: Icons.menu_book,
          selected: true,
        ),
        theme: ThemeData.dark(useMaterial3: true),
        size: const Size(400, 80),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/list_tile_dark.png'),
      );
    });
  });
}
