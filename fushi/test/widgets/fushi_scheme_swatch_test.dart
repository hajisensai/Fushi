import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

/// 完整预览 = 四个角色色全部上画布：页面底 / 顶栏（菜单面）/ 文字线 / 强调色按钮。
/// 对应旧对角预览的 showGlyph（「文」字 + 按钮点都画出来，而不是只剩底色）。
bool paintsFullPreview(SchemeMiniUiPainter painter, List<Color> colors) =>
    painter.textColor == colors[0] &&
    painter.backgroundColor == colors[1] &&
    painter.buttonColor == colors[2] &&
    painter.barColor == colors[3];

void main() {
  test('swatch colours are [text, background, button, menu] of the scheme', () {
    // TODO-100: the swatch previews the four roles a user actually reads —
    // text colour, page background, button/accent, popup-menu surface — not the
    // raw seed and not primary/secondary/tertiary.
    final ColorScheme scheme = buildFushiColorScheme(
      seedColor: const Color(0xFF1F4959),
      brightness: Brightness.light,
    );
    final List<Color> colors = fushiSchemeSwatchColors(scheme);
    expect(colors, <Color>[
      scheme.onSurface,
      scheme.surface,
      scheme.primary,
      scheme.surfaceContainerHigh,
    ]);
  });

  test('swatch colours preview the generated scheme, not the raw seed', () {
    const Color seed = Color(0xFF1F4959);
    final ColorScheme scheme = buildFushiColorScheme(
      seedColor: seed,
      brightness: Brightness.light,
    );
    final List<Color> colors = fushiSchemeSwatchColors(scheme);
    // The button role (primary) is the tone-mapped result, not the raw seed —
    // otherwise we would be back to the old "怪" single-seed circle.
    expect(colors[2], isNot(equals(seed)));
  });

  test('same-seed light/dark presets yield distinguishable swatch colours', () {
    // light-theme 与 dark-theme 共用 seed 0xFF1F4959，旧单色圆只差明暗几乎分不清。
    final ColorScheme light = buildFushiColorScheme(
      seedColor: const Color(0xFF1F4959),
      brightness: Brightness.light,
    );
    final ColorScheme dark = buildFushiColorScheme(
      seedColor: const Color(0xFF1F4959),
      brightness: Brightness.dark,
    );
    final List<Color> lightColors = fushiSchemeSwatchColors(light);
    final List<Color> darkColors = fushiSchemeSwatchColors(dark);
    expect(lightColors, isNot(equals(darkColors)));
    // 背景色（colors[1]=surface）必然不同，正是区分明暗预设的关键。
    expect(lightColors[1], isNot(equals(darkColors[1])));
    // 文字色（colors[0]=onSurface）也翻转，进一步拉开明暗预设。
    expect(lightColors[0], isNot(equals(darkColors[0])));
  });

  test('current presets have distinguishable swatches in light and dark modes', () {
    // 当前预设只定义种子和变体；明暗模式独立选择。每套模式下所有预设都必须
    // 保留可辨认的四色组合，避免旧单种子色点掩盖实际主题差异（TODO-100）。
    final List<String> keys = AppModel.themePresets.keys.toList();
    expect(keys, containsAll(<String>['m3-baseline', 'm3-blue', 'm3-neutral']));
    for (final Brightness brightness in Brightness.values) {
      final List<List<Color>> swatches = keys.map((String key) {
        final ThemePreset preset = AppModel.themePresets[key]!;
        return fushiSchemeSwatchColors(
          AppModel.buildPresetColorScheme(preset, brightness),
        );
      }).toList();
      for (int i = 0; i < swatches.length; i++) {
        for (int j = i + 1; j < swatches.length; j++) {
          expect(
            swatches[i],
            isNot(equals(swatches[j])),
            reason: '${keys[i]} 与 ${keys[j]} 在 $brightness 下色板四色完全相同',
          );
        }
      }
    }
  });

  testWidgets('FushiSchemeSwatch fires onTap and paints the diagonal preview',
      (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(
          body: Center(
            child: FushiSchemeSwatch(
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
    await tester.tap(find.byType(FushiSchemeSwatch));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets('TODO-928 · onTap (切换) 与 onLongPress (编辑) 各自独立触发',
      (WidgetTester tester) async {
    int taps = 0;
    int longPresses = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(
          body: Center(
            child: FushiSchemeSwatch(
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
    await tester.tap(find.byType(FushiSchemeSwatch));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(longPresses, 0);
    // 长按只触发编辑，不触发切换。
    await tester.longPress(find.byType(FushiSchemeSwatch));
    await tester.pumpAndSettle();
    expect(longPresses, 1);
    expect(taps, 1);
  });

  testWidgets('TODO-928 · onLongPress 可选：不传也不抛（向后兼容）',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(
          body: Center(
            child: FushiSchemeSwatch(
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
    await tester.longPress(find.byType(FushiSchemeSwatch));
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
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(
          body: Center(
            child: FushiSchemeSwatch(
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
    // 2026-10-04 主题图标重设计：预览画布（SchemeMiniUiPainter）的页面底就是
    // 方案背景色；选中环是色板外留缝套的 AnimatedContainer 圆角描边。
    final SchemeMiniUiPainter painter = tester
        .widget<CustomPaint>(
          find.descendant(
            of: find.byType(FushiSchemeSwatch),
            matching: find.byWidgetPredicate(
              (Widget w) => w is CustomPaint && w.painter is SchemeMiniUiPainter,
            ),
          ),
        )
        .painter! as SchemeMiniUiPainter;
    expect(painter.backgroundColor, background,
        reason: 'card preview fill is the scheme background');
    final AnimatedContainer container = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(FushiSchemeSwatch),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect(container.foregroundDecoration, isNull);
    final BoxDecoration card = container.decoration! as BoxDecoration;
    final Border ring = card.border! as Border;
    expect(ring.top.color, Theme.of(tester.element(find.byType(FushiSchemeSwatch))).colorScheme.primary,
        reason: 'selection ring rides the card in the accent colour');
    expect(card.borderRadius, isNotNull,
        reason: 'rounded square, not a full circle');
  });

  group('TODO-138 · 所有主题指示器都显示完整对角预览（不只底色）', () {
    SchemeMiniUiPainter painterOf(WidgetTester tester) {
      final CustomPaint cp = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(FushiSchemeSwatch),
          matching: find.byWidgetPredicate(
            (Widget w) =>
                w is CustomPaint && w.painter is SchemeMiniUiPainter,
          ),
        ),
      );
      return cp.painter! as SchemeMiniUiPainter;
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
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: Scaffold(
            body: Center(child: FushiSchemeSwatch(colors: colors)),
          ),
        ),
      );
      expect(paintsFullPreview(painterOf(tester), colors), isTrue);
    });

    testWidgets('system/custom swatch（有 overlay）也画完整预览（含「文」glyph）',
        (WidgetTester tester) async {
      // 这是 TODO-138 的核心：旧实现 overlay != null → showGlyph=false +
      // 居中徽章盖住对角预览，只剩底色。撤回旧实现这条会红。
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: Scaffold(
            body: Center(
              child: FushiSchemeSwatch(
                colors: colors,
                overlay: Icon(Icons.palette_outlined),
              ),
            ),
          ),
        ),
      );
      expect(paintsFullPreview(painterOf(tester), colors), isTrue,
          reason: 'system/custom 也必须画完整预览，不能只剩底色 + 居中徽章');
    });

    testWidgets('selected swatch 仍画完整预览（含「文」glyph）',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: Scaffold(
            body: Center(
              child: FushiSchemeSwatch(
                colors: colors,
                selected: true,
                overlay: Icon(Icons.auto_awesome_outlined),
              ),
            ),
          ),
        ),
      );
      expect(paintsFullPreview(painterOf(tester), colors), isTrue);
    });

    testWidgets('overlay 徽章放角落（右下），不再居中盖住预览',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: Scaffold(
            body: Center(
              child: FushiSchemeSwatch(
                colors: colors,
                overlay: Icon(Icons.palette_outlined),
              ),
            ),
          ),
        ),
      );
      // 徽章经 Positioned(right/bottom) 定位在右下角（让出中央完整预览），
      // 而不是旧的 Center 居中盖住。
      final Finder badgeAlign = find.descendant(
        of: find.byType(FushiSchemeSwatch),
        matching: find.byWidgetPredicate(
          (Widget w) =>
              w is Positioned &&
              w.right != null &&
              w.bottom != null &&
              w.top == null &&
              w.left == null,
        ),
      );
      expect(badgeAlign, findsOneWidget);
      // overlay 图标仍然渲染（徽章没被丢弃，只是移到角落）。
      expect(
        find.descendant(
          of: find.byType(FushiSchemeSwatch),
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
      // 徽章直径 = size*0.34，图标 = 直径*0.62（默认 size 48）。
      expect(iconTheme.size, closeTo(48 * 0.34 * 0.62, 0.001),
          reason: '应读到徽章那层的 IconTheme');
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
      final ColorScheme darkAppScheme = buildFushiColorScheme(
        seedColor: const Color(0xFF1F4959),
        brightness: Brightness.dark,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.from(colorScheme: darkAppScheme).copyWith(
            splashFactory: NoSplash.splashFactory,
          ),
          home: Scaffold(
            body: Center(
              child: FushiSchemeSwatch(
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
      final ColorScheme lightAppScheme = buildFushiColorScheme(
        seedColor: const Color(0xFF1F4959),
        brightness: Brightness.light,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.from(colorScheme: lightAppScheme).copyWith(
            splashFactory: NoSplash.splashFactory,
          ),
          home: Scaffold(
            body: Center(
              child: FushiSchemeSwatch(
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
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: Scaffold(
            body: Center(
              child: FushiSchemeSwatch(
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

  group('TODO-1320 · 主题卡片恒完整显示、下方无多余文字', () {
    // 用户诉求：①删掉自定义主题底下的名字文字 ②所有主题卡片都完整显示配色，
    // 而不是选中以后才完整。这里在 widget 行为层锁死：无论选中与否，swatch 都画
    // 完整对角预览（含「文」glyph），且 swatch 自身结构里不含任何 Text caption
    // （FushiSchemeSwatch 已删除 label/textColor，无法再挂底部文字）。
    const List<Color> colors = <Color>[
      Color(0xFF112233),
      Color(0xFF445566),
      Color(0xFF778899),
      Color(0xFFAABBCC),
    ];

    SchemeMiniUiPainter painterOf(WidgetTester tester) {
      final CustomPaint cp = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(FushiSchemeSwatch),
          matching: find.byWidgetPredicate(
            (Widget w) =>
                w is CustomPaint && w.painter is SchemeMiniUiPainter,
          ),
        ),
      );
      return cp.painter! as SchemeMiniUiPainter;
    }

    // TODO-1320 回归守卫：光有 painter.showGlyph==true 不够——若 CustomPaint 画布塌成
    // Size.zero（childless CustomPaint 在父级 loose 约束下的默认行为），预览一个像素
    // 都画不出来，卡片就是空白圆角块。这里量真实渲染尺寸，锁死画布非空。
    Size paintSizeOf(WidgetTester tester) => tester.getSize(
          find.descendant(
            of: find.byType(FushiSchemeSwatch),
            matching: find.byWidgetPredicate(
              (Widget w) =>
                  w is CustomPaint && w.painter is SchemeMiniUiPainter,
            ),
          ),
        );

    Future<void> pumpSwatch(
      WidgetTester tester, {
      required bool selected,
      Widget? overlay,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: Scaffold(
            body: Center(
              child: FushiSchemeSwatch(
                colors: colors,
                selected: selected,
                overlay: overlay,
                onTap: () {},
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('未选中的主题卡片也画完整对角预览（含「文」glyph）', (WidgetTester tester) async {
      await pumpSwatch(tester, selected: false);
      expect(paintsFullPreview(painterOf(tester), colors), isTrue,
          reason: '未选中的主题卡片必须完整显示配色，而不是选中后才完整');
    });

    testWidgets('未选中的主题卡片内不含任何底部文字（Text）', (WidgetTester tester) async {
      await pumpSwatch(tester, selected: false);
      // 「文」glyph 由 CustomPaint/TextPainter 绘制，不是 Text widget；故 swatch
      // 内出现 Text 只可能来自曾经的 caption。删除 label 后必须一个都没有。
      expect(
        find.descendant(
          of: find.byType(FushiSchemeSwatch),
          matching: find.byType(Text),
        ),
        findsNothing,
        reason: '主题卡片下方不能再有名称/说明文字',
      );
    });

    testWidgets('选中的主题卡片同样完整预览且无底部文字', (WidgetTester tester) async {
      await pumpSwatch(tester, selected: true, overlay: const Icon(Icons.add));
      expect(paintsFullPreview(painterOf(tester), colors), isTrue);
      expect(
        find.descendant(
          of: find.byType(FushiSchemeSwatch),
          matching: find.byType(Text),
        ),
        findsNothing,
      );
    });

    testWidgets('未选中的预设主题卡片预览画布必须非空（回归：TODO-1320 未选中空白卡）',
        (WidgetTester tester) async {
      // 预设 swatch 未选中时没有徽章 child（既非选中的对勾、也非 system/custom 的
      // overlay）。修复前 CustomPaint 因此塌成 0x0，整张卡是空白圆角块——本用例正是
      // 用真实渲染尺寸把它钉死：画布必须铺满卡片、非零，才能画出完整对角预览。
      await pumpSwatch(tester, selected: false);
      final Size size = paintSizeOf(tester);
      expect(size.width, greaterThan(0), reason: '未选中预设卡片的预览画布宽度必须非零，否则整张卡空白');
      expect(size.height, greaterThan(0), reason: '未选中预设卡片的预览画布高度必须非零，否则整张卡空白');
    });

    testWidgets('选中 / 系统 / 自定义 swatch 的预览画布同样非空', (WidgetTester tester) async {
      // 反向对照：选中卡（对勾 child）与 system/custom（overlay child）本就非空，
      // 一并守住，防止未来改动把「有 child 才非空」这个隐性依赖反向破坏掉。
      await pumpSwatch(tester, selected: true);
      expect(paintSizeOf(tester).shortestSide, greaterThan(0));
      await pumpSwatch(tester,
          selected: false, overlay: const Icon(Icons.auto_awesome));
      expect(paintSizeOf(tester).shortestSide, greaterThan(0));
    });
  });
}
