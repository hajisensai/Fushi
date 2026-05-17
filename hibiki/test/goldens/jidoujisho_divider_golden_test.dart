import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/jidoujisho_divider.dart';

import 'golden_test_helpers.dart';

void main() {
  group('JidoujishoDivider golden', () {
    testWidgets('light theme', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const JidoujishoDivider(),
        size: const Size(300, 30),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/divider_light.png'),
      );
    });

    testWidgets('dark theme', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const JidoujishoDivider(),
        theme: ThemeData.dark(useMaterial3: true),
        size: const Size(300, 30),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/divider_dark.png'),
      );
    });
  });
}
