import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/Hibiki_dropdown.dart';

import 'widget_test_helpers.dart';

void main() {
  group('HibikiDropdown', () {
    testWidgets('shows initial option label', (tester) async {
      await tester.pumpWidget(buildTestApp(
        HibikiDropdown<String>(
          options: const ['Apple', 'Banana', 'Cherry'],
          initialOption: 'Banana',
          generateLabel: (v) => v,
          onChanged: (_) {},
        ),
      ));

      expect(find.text('  Banana'), findsOneWidget);
    });

    testWidgets('calls onChanged when new option selected', (tester) async {
      String? selected;
      await tester.pumpWidget(buildTestApp(
        HibikiDropdown<String>(
          options: const ['A', 'B'],
          initialOption: 'A',
          generateLabel: (v) => v,
          onChanged: (v) => selected = v,
        ),
      ));

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();

      await tester.tap(find.text('  B').last);
      await tester.pumpAndSettle();

      expect(selected, 'B');
    });

    testWidgets('disabled dropdown has null onChanged', (tester) async {
      bool changed = false;
      await tester.pumpWidget(buildTestApp(
        HibikiDropdown<String>(
          options: const ['X', 'Y'],
          initialOption: 'X',
          generateLabel: (v) => v,
          onChanged: (_) => changed = true,
          enabled: false,
        ),
      ));

      final DropdownButton<String> dropdown =
          tester.widget(find.byType(DropdownButton<String>));
      expect(dropdown.onChanged, isNull);
      expect(changed, isFalse);
    });

    testWidgets('deduplicates options via toSet', (tester) async {
      await tester.pumpWidget(buildTestApp(
        HibikiDropdown<String>(
          options: const ['A', 'A', 'B'],
          initialOption: 'A',
          generateLabel: (v) => v,
          onChanged: (_) {},
        ),
      ));

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();

      // 2 unique items: each shown twice (button + overlay)
      expect(find.text('  A'), findsNWidgets(2));
      expect(find.text('  B'), findsOneWidget);
    });

    testWidgets('falls back to first option when initial not in list',
        (tester) async {
      await tester.pumpWidget(buildTestApp(
        HibikiDropdown<String>(
          options: const ['X', 'Y'],
          initialOption: 'Z',
          generateLabel: (v) => v,
          onChanged: (_) {},
        ),
      ));

      expect(find.text('  X'), findsOneWidget);
    });
  });
}
