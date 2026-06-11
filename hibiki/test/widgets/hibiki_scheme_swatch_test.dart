import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

void main() {
  test('swatch colours are [text, background, button, menu] of the scheme', () {
    // TODO-100: the swatch previews the four roles a user actually reads —
    // text colour, page background, button/accent, popup-menu surface — not the
    // raw seed and not primary/secondary/tertiary.
    final ColorScheme scheme = buildHibikiColorScheme(
      seedColor: const Color(0xFF1F4959),
      brightness: Brightness.light,
    );
    final List<Color> colors = hibikiSchemeSwatchColors(scheme);
    expect(colors, <Color>[
      scheme.onSurface,
      scheme.surface,
      scheme.primary,
      scheme.surfaceContainerHigh,
    ]);
  });

  test('swatch colours preview the generated scheme, not the raw seed', () {
    const Color seed = Color(0xFF1F4959);
    final ColorScheme scheme = buildHibikiColorScheme(
      seedColor: seed,
      brightness: Brightness.light,
    );
    final List<Color> colors = hibikiSchemeSwatchColors(scheme);
    // The button role (primary) is the tone-mapped result, not the raw seed —
    // otherwise we would be back to the old "怪" single-seed circle.
    expect(colors[2], isNot(equals(seed)));
  });

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
    // 背景色（colors[1]=surface）必然不同，正是区分明暗预设的关键。
    expect(lightColors[1], isNot(equals(darkColors[1])));
    // 文字色（colors[0]=onSurface）也翻转，进一步拉开明暗预设。
    expect(lightColors[0], isNot(equals(darkColors[0])));
  });

  test('the three dark presets are visibly distinct swatches (TODO-100)', () {
    // 用户报「三个暗色主题选择时完全看不出差别」。三个暗色预设种子不同，
    // 经 M3 fromSeed 后背景/文字/按钮组合必须各不相同，色板才能一眼区分。
    final List<String> darkKeys = <String>[
      'gray-theme',
      'dark-theme',
      'black-theme',
    ];
    final List<List<Color>> swatches = darkKeys.map((String key) {
      final ({
        Color seed,
        Brightness brightness,
        DynamicSchemeVariant variant
      }) preset = AppModel.themePresets[key]!;
      return hibikiSchemeSwatchColors(
        buildHibikiColorScheme(
          seedColor: preset.seed,
          brightness: preset.brightness,
          variant: preset.variant,
        ),
      );
    }).toList();
    // 每一对暗色预设的四色组合都必须不同（不存在两个完全一样的暗色色板）。
    for (int i = 0; i < swatches.length; i++) {
      for (int j = i + 1; j < swatches.length; j++) {
        expect(
          swatches[i],
          isNot(equals(swatches[j])),
          reason: '${darkKeys[i]} 与 ${darkKeys[j]} 的色板四色完全相同，看不出差别',
        );
      }
    }
  });

  testWidgets('HibikiSchemeSwatch fires onTap and paints the diagonal preview',
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

  testWidgets('rounded card uses the background colour as fill + ring',
      (WidgetTester tester) async {
    // The swatch is a rounded-square card whose decoration fill IS the scheme
    // background (colours[1]); the painter draws the diagonal preview on top and
    // clips inside the border, so the selection ring on the card border stays
    // visible (no foregroundDecoration needed).
    const Color background = Color(0xFF445566);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: HibikiSchemeSwatch(
              colors: const <Color>[
                Color(0xFF112233),
                background,
                Color(0xFF778899),
                Color(0xFFAABBCC),
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
    expect(card.color, background,
        reason: 'card decoration fill is the scheme background');
    expect(card.border, isNotNull, reason: 'selection ring rides the card');
    expect(card.borderRadius, isNotNull,
        reason: 'rounded square, not a full circle');
  });

  group('TODO-138 · 所有主题指示器都显示完整对角预览（不只底色）', () {
    SchemeDiagonalPainter painterOf(WidgetTester tester) {
      final CustomPaint cp = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(HibikiSchemeSwatch),
          matching: find.byWidgetPredicate(
            (Widget w) =>
                w is CustomPaint && w.painter is SchemeDiagonalPainter,
          ),
        ),
      );
      return cp.painter! as SchemeDiagonalPainter;
    }

    const List<Color> colors = <Color>[
      Color(0xFF112233),
      Color(0xFF445566),
      Color(0xFF778899),
      Color(0xFFAABBCC),
    ];

    testWidgets('preset swatch（无 overlay）画完整预览（含「文」glyph）',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(child: HibikiSchemeSwatch(colors: colors)),
          ),
        ),
      );
      expect(painterOf(tester).showGlyph, isTrue);
    });

    testWidgets('system/custom swatch（有 overlay）也画完整预览（含「文」glyph）',
        (WidgetTester tester) async {
      // 这是 TODO-138 的核心：旧实现 overlay != null → showGlyph=false +
      // 居中徽章盖住对角预览，只剩底色。撤回旧实现这条会红。
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: HibikiSchemeSwatch(
                colors: colors,
                overlay: Icon(Icons.palette_outlined),
              ),
            ),
          ),
        ),
      );
      expect(painterOf(tester).showGlyph, isTrue,
          reason: 'system/custom 也必须画完整预览，不能只剩底色 + 居中徽章');
    });

    testWidgets('selected swatch 仍画完整预览（含「文」glyph）',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: HibikiSchemeSwatch(
                colors: colors,
                selected: true,
                overlay: Icon(Icons.auto_awesome_outlined),
              ),
            ),
          ),
        ),
      );
      expect(painterOf(tester).showGlyph, isTrue);
    });

    testWidgets('overlay 徽章放角落（bottomLeft），不再居中盖住预览',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: HibikiSchemeSwatch(
                colors: colors,
                overlay: Icon(Icons.palette_outlined),
              ),
            ),
          ),
        ),
      );
      // 徽章经 Align(bottomLeft) 定位在角落（让出中央完整预览），
      // 而不是旧的 Center 居中盖住。
      final Finder badgeAlign = find.descendant(
        of: find.byType(HibikiSchemeSwatch),
        matching: find.byWidgetPredicate(
          (Widget w) => w is Align && w.alignment == Alignment.bottomLeft,
        ),
      );
      expect(badgeAlign, findsOneWidget);
      // overlay 图标仍然渲染（徽章没被丢弃，只是移到角落）。
      expect(
        find.descendant(
          of: find.byType(HibikiSchemeSwatch),
          matching: find.byIcon(Icons.palette_outlined),
        ),
        findsOneWidget,
      );
    });
  });
}
