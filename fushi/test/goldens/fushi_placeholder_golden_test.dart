@Tags(<String>['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';

import 'golden_test_helpers.dart';

void main() {
  group('FushiPlaceholderMessage golden', () {
    testWidgets('default style', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const FushiPlaceholderMessage(
          icon: Icons.book,
          message: 'No books yet',
        ),
        size: const Size(300, 190),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/placeholder_default.png'),
      );
    });

    testWidgets('custom color', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const FushiPlaceholderMessage(
          icon: Icons.error_outline,
          message: 'Something went wrong',
          color: Colors.red,
        ),
        size: const Size(300, 190),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/placeholder_error.png'),
      );
    });

    testWidgets('dark theme', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const FushiPlaceholderMessage(
          icon: Icons.search_off,
          message: 'No results found',
        ),
        theme: ThemeData.dark(useMaterial3: true),
        size: const Size(300, 190),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/placeholder_dark.png'),
      );
    });
  });
}
