@Tags(<String>['golden'])
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_list_tile.dart';

import 'golden_test_helpers.dart';

void main() {
  group('FushiListTile extended golden', () {
    testWidgets('multi-word title and subtitle', (tester) async {
      await tester.pumpWidget(
        buildGoldenApp(
          const FushiListTile(
            title: '明鏡国語辞典 第三版',
            subtitle: 'JA-JA monolingual',
            icon: Icons.menu_book,
            selected: false,
          ),
          size: const Size(400, 80),
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/list_tile_long_text.png'),
      );
    });

    testWidgets('narrow width', (tester) async {
      await tester.pumpWidget(
        buildGoldenApp(
          const FushiListTile(
            title: 'Dict',
            subtitle: 'JA',
            icon: Icons.book,
            selected: true,
          ),
          size: const Size(150, 80),
        ),
      );
      // 150 宽里标题按实际字号放不下：走跑马灯（BUG-4237 前按 14px 默认字量、误判
      // 放得下，画成截断的「Di…」）。跑马灯一直滚、不会 settle，取首帧。
      await tester.pump();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/list_tile_narrow.png'),
      );
      // 卸掉跑马灯，别留下滚动计时器。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('wide layout', (tester) async {
      await tester.pumpWidget(
        buildGoldenApp(
          const FushiListTile(
            title: '明鏡国語辞典',
            subtitle: 'JA-JA 国語辞典',
            icon: Icons.translate,
            selected: true,
            trailing: Icon(Icons.check_circle, color: Colors.green),
          ),
          size: const Size(600, 80),
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/list_tile_wide.png'),
      );
    });

    testWidgets('custom seed color theme selected', (tester) async {
      await tester.pumpWidget(
        buildGoldenApp(
          const FushiListTile(
            title: 'Seeded theme',
            subtitle: 'Material You color',
            icon: Icons.palette,
            selected: true,
          ),
          theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
          size: const Size(400, 80),
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/list_tile_seed_theme.png'),
      );
    });

    testWidgets('high contrast dark theme', (tester) async {
      await tester.pumpWidget(
        buildGoldenApp(
          const FushiListTile(
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
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/list_tile_high_contrast.png'),
      );
    });
  });
}
