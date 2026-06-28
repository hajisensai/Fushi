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

  testWidgets('TODO-928 · onTap (切换) 与 onLongPress (编辑) 各自独立触发',
      (WidgetTester tester) async {
    int taps = 0;
    int longPresses = 0;
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
              onLongPress: () => longPresses++,
            ),
          ),
        ),
      ),
    );
    // 单击只触发切换，不触发编辑。
    await tester.tap(find.byType(HibikiSchemeSwatch));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(longPresses, 0);
    // 长按只触发编辑，不触发切换。
    await tester.longPress(find.byType(HibikiSchemeSwatch));
    await tester.pumpAndSettle();
    expect(longPresses, 1);
    expect(taps, 1);
  });

  testWidgets('TODO-928 · onLongPress 可选：不传也不抛（向后兼容）',
      (WidgetTester tester) async {
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
            ),
          ),
        ),
      ),
    );
    await tester.longPress(find.byType(HibikiSchemeSwatch));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
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

  group('BUG-212 · 徽章图标随徽章背景取对比，不借 app 主题 onSurface', () {
    // 读徽章图标实际生效的颜色：用 Icon 自己的 BuildContext 解析 IconTheme.of，
    // 这正是 Icon 渲染时读到的颜色（用户真正看到的）。旧实现 = app 主题
    // cs.onSurface（深色主题下浅色），修复后 = _swatchForegroundFor(menuRole)
    // （相对徽章自己背景取黑/白）。size==10 确认我们读的是徽章那层而非外层默认。
    Color badgeIconColor(WidgetTester tester) {
      final BuildContext iconContext =
          tester.element(find.byIcon(Icons.palette_outlined));
      final IconThemeData iconTheme = IconTheme.of(iconContext);
      expect(iconTheme.size, 10, reason: '应读到徽章那层 size==10 的 IconTheme');
      return iconTheme.color!;
    }

    // colors = [text, background, button, menu]；menu(colors[3]) 是徽章背景。
    // 故意让徽章背景是浅色，被预览方案是浅色方案的 surfaceContainerHigh。
    const Color lightMenu = Color(0xFFEFEFEF);
    const List<Color> lightSchemeColors = <Color>[
      Color(0xFF1A1A1A), // text / onSurface（浅色方案里是深色）
      Color(0xFFFDFDFD), // background / surface
      Color(0xFF3366AA), // button / primary
      lightMenu, // menu / surfaceContainerHigh —— 徽章背景
    ];

    testWidgets('深色 app 主题 + 浅色徽章背景：图标取黑色对比，仍可见', (WidgetTester tester) async {
      // 深色 app 主题下 cs.onSurface 是浅色（近白）。旧实现会把图标涂成它，
      // 浅图标画在浅色徽章背景上 → 用户看不见。这正是「黑色主题下调色盘消失」。
      final ColorScheme darkAppScheme = buildHibikiColorScheme(
        seedColor: const Color(0xFF1F4959),
        brightness: Brightness.dark,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.from(colorScheme: darkAppScheme),
          home: Scaffold(
            body: Center(
              child: HibikiSchemeSwatch(
                colors: lightSchemeColors,
                overlay: const Icon(Icons.palette_outlined),
              ),
            ),
          ),
        ),
      );
      final Color iconColor = badgeIconColor(tester);
      // 修复后：相对浅色徽章背景取对比 → 黑色（可见）。
      expect(
        iconColor,
        Colors.black,
        reason: '浅色徽章背景上图标必须是黑色（可见），而不是 app 主题的浅色 onSurface',
      );
      // 反向锁死回归：图标绝不能等于深色 app 主题的浅色 onSurface
      // （那正是旧实现让图标在深色主题下消失的根因）。
      expect(
        iconColor,
        isNot(equals(darkAppScheme.onSurface)),
        reason: '不能再借 app 主题 onSurface —— 那会在深色主题 + 浅色方案下与背景撞色',
      );
    });

    testWidgets('浅色 app 主题 + 浅色徽章背景：图标同样取黑色对比（深浅主题一致）',
        (WidgetTester tester) async {
      // 用户说浅色主题下图标「还在」。修复不能破坏这一点：同一浅色徽章背景，
      // 无论 app 主题深浅，图标都应是黑色 —— 颜色只由徽章背景决定，与 app 主题无关。
      final ColorScheme lightAppScheme = buildHibikiColorScheme(
        seedColor: const Color(0xFF1F4959),
        brightness: Brightness.light,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.from(colorScheme: lightAppScheme),
          home: Scaffold(
            body: Center(
              child: HibikiSchemeSwatch(
                colors: lightSchemeColors,
                overlay: const Icon(Icons.palette_outlined),
              ),
            ),
          ),
        ),
      );
      expect(badgeIconColor(tester), Colors.black);
    });

    testWidgets('深色徽章背景：图标取白色对比（另一极也正确）', (WidgetTester tester) async {
      const Color darkMenu = Color(0xFF101010);
      const List<Color> darkSchemeColors = <Color>[
        Color(0xFFEFEFEF),
        Color(0xFF020202),
        Color(0xFF99BBFF),
        darkMenu, // 徽章背景：深色
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: HibikiSchemeSwatch(
                colors: darkSchemeColors,
                overlay: const Icon(Icons.palette_outlined),
              ),
            ),
          ),
        ),
      );
      expect(badgeIconColor(tester), Colors.white,
          reason: '深色徽章背景上图标必须是白色（可见）');
    });
  });
}
