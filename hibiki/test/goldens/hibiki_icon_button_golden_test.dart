import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/hibiki_icon_button.dart';

import 'golden_test_helpers.dart';

void main() {
  group('HibikiIconButton golden', () {
    testWidgets('enabled state', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        HibikiIconButton(
          icon: Icons.search,
          tooltip: 'Search',
          onTap: () {},
        ),
        size: const Size(80, 80),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/icon_button_enabled.png'),
      );
    });

    testWidgets('disabled state', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const HibikiIconButton(
          icon: Icons.search,
          tooltip: 'Search',
          enabled: false,
        ),
        size: const Size(80, 80),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/icon_button_disabled.png'),
      );
    });

    testWidgets('wide tap area', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        HibikiIconButton(
          icon: Icons.play_arrow,
          tooltip: 'Play',
          isWideTapArea: true,
          onTap: () {},
        ),
        size: const Size(80, 80),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/icon_button_wide.png'),
      );
    });

    testWidgets('custom colors', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        HibikiIconButton(
          icon: Icons.bookmark,
          tooltip: 'Bookmark',
          enabledColor: Colors.red,
          backgroundColor: Colors.yellow,
          onTap: () {},
        ),
        size: const Size(80, 80),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/icon_button_custom.png'),
      );
    });

    testWidgets('dark theme', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        HibikiIconButton(
          icon: Icons.settings,
          tooltip: 'Settings',
          onTap: () {},
        ),
        theme: ThemeData.dark(useMaterial3: true),
        size: const Size(80, 80),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/icon_button_dark.png'),
      );
    });
  });
}
