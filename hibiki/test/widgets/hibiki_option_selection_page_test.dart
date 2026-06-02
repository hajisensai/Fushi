import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';
import 'package:hibiki/src/utils/components/hibiki_option_selection_page.dart';

Widget _harness(Widget child) {
  return MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      platform: TargetPlatform.android,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
    ),
    home: child,
  );
}

List<HibikiOptionSelectionOption<String>> _langs() =>
    const <HibikiOptionSelectionOption<String>>[
      HibikiOptionSelectionOption<String>(value: 'en-US', label: 'English'),
      HibikiOptionSelectionOption<String>(value: 'ja', label: '日本語'),
      HibikiOptionSelectionOption<String>(value: 'zh-CN', label: '简体中文'),
    ];

void main() {
  testWidgets('selected entry shows a check; tapping another pops its value',
      (WidgetTester tester) async {
    String? popped = 'SENTINEL';
    await tester.pumpWidget(
      _harness(
        Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  popped = await pickOption<String>(
                    context,
                    title: 'Language',
                    options: _langs(),
                    selected: 'ja',
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The selected entry (日本語) renders a trailing check.
    expect(find.byIcon(Icons.check), findsOneWidget);

    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(popped, 'en-US');
  });

  testWidgets('shows a search field past the threshold and filters',
      (WidgetTester tester) async {
    final List<HibikiOptionSelectionOption<int>> many =
        List<HibikiOptionSelectionOption<int>>.generate(
      kOptionSelectionSearchThreshold + 3,
      (int i) => HibikiOptionSelectionOption<int>(value: i, label: 'Item $i'),
    );
    await tester.pumpWidget(
      _harness(
        HibikiOptionSelectionPage<int>(
          title: 'Pick',
          options: many,
          selected: 0,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(HibikiTextField), findsOneWidget);

    // 'Item 0' is a substring of no other label ('Item 10'..'Item 14' don't
    // contain it), so the list collapses to exactly that row. (find.text also
    // matches the search field's own text, so assert presence with
    // findsWidgets rather than an exact count.)
    await tester.enterText(find.byType(TextField).first, 'Item 0');
    await tester.pumpAndSettle();
    expect(find.text('Item 5'), findsNothing);
    expect(find.text('Item 0'), findsWidgets);
  });

  testWidgets('no search field below the threshold',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _harness(
        HibikiOptionSelectionPage<String>(
          title: 'Language',
          options: _langs(),
          selected: 'ja',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(HibikiTextField), findsNothing);
  });
}
