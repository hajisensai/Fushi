@Tags(<String>['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/hibiki_divider.dart';

import 'golden_test_helpers.dart';

void main() {
  group('FushiDivider golden', () {
    testWidgets('light theme', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const FushiDivider(),
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
        const FushiDivider(),
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
