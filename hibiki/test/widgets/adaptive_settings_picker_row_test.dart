import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

Widget _harness(Widget child) {
  return MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      platform: TargetPlatform.android,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
    ),
    home: Scaffold(body: child),
  );
}

AdaptiveSettingsPickerRow<int> _row(int count, {required int selected}) {
  return AdaptiveSettingsPickerRow<int>(
    title: 'Pick',
    selected: selected,
    options: <AdaptiveSettingsPickerOption<int>>[
      for (int i = 0; i < count; i++)
        AdaptiveSettingsPickerOption<int>(value: i, label: 'Opt $i'),
    ],
    onChanged: (_) {},
  );
}

void main() {
  testWidgets('short option set stays inline (no chevron navigation row)',
      (WidgetTester tester) async {
    await tester.pumpWidget(_harness(_row(3, selected: 0)));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.chevron_right), findsNothing);
  });

  testWidgets('long option set renders a chevron row and pushes a full page',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _harness(_row(kSettingsPickerInlineLimit + 1, selected: 0)),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    // The pushed page lists the options; an unselected entry is reachable.
    expect(find.text('Opt 5'), findsWidgets);
  });

  testWidgets('selecting an entry on the full page reports the chosen value',
      (WidgetTester tester) async {
    int? chosen;
    await tester.pumpWidget(
      _harness(
        AdaptiveSettingsPickerRow<int>(
          title: 'Pick',
          selected: 0,
          options: <AdaptiveSettingsPickerOption<int>>[
            for (int i = 0; i < kSettingsPickerInlineLimit + 1; i++)
              AdaptiveSettingsPickerOption<int>(value: i, label: 'Opt $i'),
          ],
          onChanged: (int v) => chosen = v,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Opt 3'));
    await tester.pumpAndSettle();
    expect(chosen, 3);
  });
}
