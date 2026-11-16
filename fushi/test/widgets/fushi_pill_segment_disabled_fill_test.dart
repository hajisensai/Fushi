import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_pill_segmented_button.dart';
import 'package:material_ui/material_ui.dart';

// 禁用的选中段：底色按 M3 禁用态取 onSurface 12%，不再是 primary 实底——否则
// 禁用文字色（onSurface 38%）压在强调色上读不出（库页「色块摆放」在封面网格下
// 置灰时的「规整」）。
void main() {
  for (final Brightness brightness in Brightness.values) {
    final ColorScheme cs = ColorScheme.fromSeed(
      seedColor: Colors.teal,
      brightness: brightness,
    );
    test('禁用选中段不画强调色实底（$brightness）', () {
      expect(
        fushiPillSegmentFill(cs, selected: true, enabled: false),
        cs.onSurface.withValues(alpha: 0.12),
      );
      expect(
        fushiPillSegmentFill(cs, selected: true, enabled: true),
        fushiPillSegmentSelectedFill(cs),
      );
      expect(fushiPillSegmentFill(cs, selected: false, enabled: true).a, 0);
      expect(fushiPillSegmentFill(cs, selected: false, enabled: false).a, 0);
    });
  }

  testWidgets('整条禁用时选中段的底色是禁用色', (WidgetTester tester) async {
    final ThemeData theme = ThemeData(colorSchemeSeed: Colors.teal);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Center(
            child: FushiPillSegmentedButton<int>(
              segments: const <ButtonSegment<int>>[
                ButtonSegment<int>(value: 0, label: Text('A'), enabled: false),
                ButtonSegment<int>(value: 1, label: Text('B'), enabled: false),
              ],
              selected: const <int>{0},
              onSelectionChanged: (Set<int> _) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Iterable<Color?> fills = tester
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
        .map(
          (AnimatedContainer c) => (c.decoration as ShapeDecoration?)?.color,
        );
    expect(
      fills,
      contains(theme.colorScheme.onSurface.withValues(alpha: 0.12)),
    );
    expect(fills, isNot(contains(theme.colorScheme.primary)));
  });
}
