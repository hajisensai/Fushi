import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

void main() {
  test('same-seed light/dark presets yield distinguishable swatch colours', () {
    // light-theme 与 dark-theme 共用 seed 0xFF1F4959，旧单色圆只差明暗几乎分不清。
    final ColorScheme light = buildHibikiColorScheme(
      seedColor: const Color(0xFF1F4959),
      brightness: Brightness.light,
    );
    final ColorScheme dark = buildHibikiColorScheme(
      seedColor: const Color(0xFF1F4959),
      brightness: Brightness.dark,
    );
    final List<Color> lightColors = hibikiSchemeSwatchColors(light);
    final List<Color> darkColors = hibikiSchemeSwatchColors(dark);
    expect(lightColors, isNot(equals(darkColors)));
    // surface（背景）必然不同，正是区分明暗预设的关键。
    expect(lightColors[3], isNot(equals(darkColors[3])));
  });

  test('swatch colours preview the generated scheme, not the raw seed', () {
    const Color seed = Color(0xFF1F4959);
    final ColorScheme scheme = buildHibikiColorScheme(
      seedColor: seed,
      brightness: Brightness.light,
    );
    final List<Color> colors = hibikiSchemeSwatchColors(scheme);
    // primary 是色调映射后的结果，不应等于原始 seed（否则就退回旧的“怪”行为）。
    expect(colors[0], isNot(equals(seed)));
    expect(colors, <Color>[
      scheme.primary,
      scheme.secondary,
      scheme.tertiary,
      scheme.surface,
    ]);
  });

  testWidgets('HibikiSchemeSwatch fires onTap and paints the accent dot',
      (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: HibikiSchemeSwatch(
              colors: const <Color>[
                Color(0xFF112233),
                Color(0xFF445566),
                Color(0xFF778899),
                Color(0xFFAABBCC),
              ],
              onTap: () => taps++,
            ),
          ),
        ),
      ),
    );
    expect(find.byType(CustomPaint), findsWidgets);
    await tester.tap(find.byType(HibikiSchemeSwatch));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets('rounded card uses the surface colour as background + ring',
      (WidgetTester tester) async {
    // The swatch is a rounded-square card whose background IS the scheme surface
    // (colours[3]); the selection ring rides the card border. The inner accent
    // dot is centred and never reaches the edge, so the border is on `decoration`
    // (visible) — no foregroundDecoration needed.
    const Color surface = Color(0xFFAABBCC);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: HibikiSchemeSwatch(
              colors: const <Color>[
                Color(0xFF112233),
                Color(0xFF445566),
                Color(0xFF778899),
                surface,
              ],
              selected: true,
            ),
          ),
        ),
      ),
    );
    final AnimatedContainer container = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(HibikiSchemeSwatch),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect(container.foregroundDecoration, isNull);
    final BoxDecoration card = container.decoration! as BoxDecoration;
    expect(card.color, surface,
        reason: 'card background is the scheme surface');
    expect(card.border, isNotNull, reason: 'selection ring rides the card');
    expect(card.borderRadius, isNotNull,
        reason: 'rounded square, not a full circle');
  });
}
