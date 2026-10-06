import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

// M3 Expressive 交互控件共享层（fushi_expressive_controls.dart）的契约：
// ① 尺寸档 / 形状 / toggle / split / FAB / FAB menu / 滑块尺寸 / chip 强调色
//    在 MD3 下按 Compose token 出几何与配色，树里仍是原 Material 控件（老测试的
//    find.byType 照常命中）；
// ② 键盘 Enter 能激活（App 把裸空格中和了），FAB menu Esc 收起；
// ③ 减少动画 / 墨水屏下形变静止（方形按钮仍是静态圆角矩形）；
// ④ Apple 设计系统下同一 API 映射到玻璃形态，不出现 Expressive 形变。
void main() {
  late bool Function() originalShaderSupport;
  setUp(() {
    originalShaderSupport = debugShaderFilterSupported;
    debugShaderFilterSupported = () => true;
  });
  tearDown(() => debugShaderFilterSupported = originalShaderSupport);

  ThemeData theme({bool glass = false, bool eink = false}) =>
      buildFushiThemeData(
        scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        textTheme: Typography.material2021().black,
        glass: glass ? FushiGlassMaterial.liquid : FushiGlassMaterial.off,
        glassDesign: glass,
        eink: eink,
      );

  Future<void> pumpHost(
    WidgetTester tester,
    Widget Function(StateSetter setState) builder, {
    bool glass = false,
    bool eink = false,
    bool reduceMotion = false,
    Widget? fab,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme(glass: glass, eink: eink),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: FushiGlassScope(
            child: Scaffold(
              floatingActionButton: fab,
              body: Center(
                child: StatefulBuilder(
                  builder: (BuildContext context, StateSetter setState) =>
                      builder(setState),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> pressEnter(WidgetTester tester, FocusNode node) async {
    node.requestFocus();
    await tester.pump();
    expect(node.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
  }

  /// 点按 / 按键只是启动弹簧，ticker 在**下一帧**才记下起点：只泵一次带时长
  /// 的帧时，那一帧恰是首帧（elapsed = 0），弹簧还停在起点。先泵一帧让动画
  /// 开跑，再推进 [ms] 毫秒。
  Future<void> advance(WidgetTester tester, int ms) async {
    await tester.pump();
    await tester.pump(Duration(milliseconds: ms));
  }

  // 弹簧在判定落定（吸附终值）前还有余振（600ms 时约 0.003 px），量化到
  // 0.1 px 再比：肉眼不可见，仍能分清 8 / 12 / 16 / 20 / 48 这些档位。
  double q(double v) => (v * 10).roundToDouble() / 10;
  Radius qr(Radius r) => Radius.elliptical(q(r.x), q(r.y));

  BorderRadius? resolvedRadius(WidgetTester tester, Finder material) {
    final Material m = tester.widget<Material>(material);
    final ShapeBorder? shape = m.shape;
    if (shape is RoundedRectangleBorder) {
      final BorderRadius br = shape.borderRadius.resolve(TextDirection.ltr);
      return BorderRadius.only(
        topLeft: qr(br.topLeft),
        topRight: qr(br.topRight),
        bottomLeft: qr(br.bottomLeft),
        bottomRight: qr(br.bottomRight),
      );
    }
    if (shape is FushiMorphBorder) {
      final Size size = tester.getSize(material);
      final Path path = shape.getOuterPath(Offset.zero & size);
      // 取左上角：路径包围盒左上点到第一个非角点的距离不好量，直接比形状参数。
      // Path 以 float32 存点：非整数宽（80.3）读回差 1e-6 量级。
      final Size bounds = path.getBounds().size;
      expect(bounds.width, closeTo(size.width, 1e-3));
      expect(bounds.height, closeTo(size.height, 1e-3));
      final double half = size.shortestSide / 2;
      final double r =
          (shape.radius + (half - shape.radius) * shape.startPill.clamp(0, 1))
              .clamp(0.0, half);
      return BorderRadius.circular(q(r));
    }
    return null;
  }

  group('FushiButtonMetrics', () {
    test('Compose token 尺寸表', () {
      expect(
        FushiButtonSize.values.map((FushiButtonSize s) {
          final FushiButtonMetrics m = FushiButtonMetrics.of(s);
          return <double>[
            m.height,
            m.squareRadius,
            m.pressedRadius,
            m.iconSize,
            m.outlineWidth,
          ];
        }).toList(),
        <List<double>>[
          <double>[32, 12, 8, 20, 1],
          <double>[40, 12, 8, 20, 1],
          <double>[56, 16, 12, 24, 1],
          <double>[96, 28, 16, 32, 2],
          <double>[136, 28, 16, 40, 3],
        ],
      );
    });

    test('toggle：圆形选中变方、方形选中变圆', () {
      expect(
        fushiButtonMorphSpec(
          FushiButtonSize.m,
          FushiButtonShape.round,
          selected: true,
        ).squared,
        isTrue,
      );
      expect(
        fushiButtonMorphSpec(
          FushiButtonSize.m,
          FushiButtonShape.square,
          selected: true,
        ).squared,
        isFalse,
      );
      expect(
        fushiButtonMorphSpec(
          FushiButtonSize.m,
          FushiButtonShape.square,
        ).squared,
        isTrue,
      );
    });
  });

  group('按钮尺寸档', () {
    testWidgets('MD3 各档高度，树里仍是 FilledButton', (WidgetTester tester) async {
      await pumpHost(
        tester,
        (_) => Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final FushiButtonSize s in FushiButtonSize.values)
              FushiFilledButton(
                key: ValueKey<FushiButtonSize>(s),
                size: s,
                onPressed: () {},
                child: const Text('Go'),
              ),
          ],
        ),
      );
      expect(find.byType(FilledButton), findsNWidgets(5));
      final Map<FushiButtonSize, double> expected = <FushiButtonSize, double>{
        FushiButtonSize.xs: 32,
        FushiButtonSize.s: 40,
        FushiButtonSize.m: 56,
        FushiButtonSize.l: 96,
        FushiButtonSize.xl: 136,
      };
      for (final MapEntry<FushiButtonSize, double> e in expected.entries) {
        final Finder material = find.descendant(
          of: find.byKey(ValueKey<FushiButtonSize>(e.key)),
          matching: find.byType(Material),
        );
        expect(tester.getSize(material.first).height, e.value, reason: '$e');
      }
    });

    testWidgets('默认（无 size、圆形）与改造前一致：40 高胶囊', (WidgetTester tester) async {
      await pumpHost(
        tester,
        (_) => FushiOutlinedButton(onPressed: () {}, child: const Text('Go')),
      );
      final Finder material = find.descendant(
        of: find.byType(OutlinedButton),
        matching: find.byType(Material),
      );
      expect(tester.getSize(material.first).height, 40);
    });

    testWidgets('方形按钮常驻圆角；减少动画下仍是静态方圆角', (WidgetTester tester) async {
      for (final bool reduce in <bool>[false, true]) {
        await pumpHost(
          tester,
          (_) => FushiFilledButton(
            size: FushiButtonSize.m,
            shape: FushiButtonShape.square,
            onPressed: () {},
            child: const Text('Go'),
          ),
          reduceMotion: reduce,
        );
        await tester.pump(const Duration(milliseconds: 600));
        final Finder material = find
            .descendant(
              of: find.byType(FilledButton),
              matching: find.byType(Material),
            )
            .first;
        expect(
          resolvedRadius(tester, material),
          BorderRadius.circular(16),
          reason: 'reduceMotion=$reduce',
        );
      }
    });

    testWidgets('按下圆角收缩（弹簧），松手复原', (WidgetTester tester) async {
      await pumpHost(
        tester,
        (_) => FushiFilledButton(
          size: FushiButtonSize.l,
          onPressed: () {},
          child: const Text('Go'),
        ),
      );
      final Finder material = find
          .descendant(
            of: find.byType(FilledButton),
            matching: find.byType(Material),
          )
          .first;
      expect(resolvedRadius(tester, material), BorderRadius.circular(48));
      final TestGesture g = await tester.startGesture(
        tester.getCenter(find.byType(FilledButton)),
      );
      await advance(tester, 600);
      expect(resolvedRadius(tester, material), BorderRadius.circular(16));
      await g.up();
      await advance(tester, 600);
      expect(resolvedRadius(tester, material), BorderRadius.circular(48));
    });
  });

  group('FushiToggleButton', () {
    testWidgets('点击 / Enter 切换，选中变方 + primary 底，带 toggled 语义', (
      WidgetTester tester,
    ) async {
      bool on = false;
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);
      await pumpHost(
        tester,
        (StateSetter setState) => FushiToggleButton(
          selected: on,
          focusNode: node,
          onChanged: (bool v) => setState(() => on = v),
          icon: const Icon(Icons.bookmark_border),
          selectedIcon: const Icon(Icons.bookmark),
          label: const Text('Save'),
        ),
      );
      expect(find.byType(FilledButton), findsOneWidget);
      await tester.tap(find.byType(FilledButton));
      await advance(tester, 600);
      expect(on, isTrue);
      expect(find.byIcon(Icons.bookmark), findsOneWidget);
      final Finder material = find
          .descendant(
            of: find.byType(FilledButton),
            matching: find.byType(Material),
          )
          .first;
      expect(resolvedRadius(tester, material), BorderRadius.circular(12));
      expect(
        tester.widget<Material>(material).color,
        Theme.of(tester.element(material)).colorScheme.primary,
      );
      final Semantics semantics = tester.widget<Semantics>(
        find
            .ancestor(
              of: find.byType(FilledButton),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(semantics.properties.toggled, isTrue);
      await pressEnter(tester, node);
      expect(on, isFalse);
    });

    testWidgets('Apple 设计系统：玻璃按钮，无 Expressive 形变', (WidgetTester tester) async {
      bool on = true;
      await pumpHost(
        tester,
        (StateSetter setState) => FushiToggleButton(
          selected: on,
          onChanged: (bool v) => setState(() => on = v),
          label: const Text('Save'),
        ),
        glass: true,
      );
      expect(find.byType(FushiPressMorph), findsNothing);
      expect(find.byType(FushiFilledButton), findsOneWidget);
    });
  });

  group('FushiSplitButton', () {
    testWidgets('主按钮触发 onPressed；尾按钮开菜单、Esc 关闭、箭头翻转', (
      WidgetTester tester,
    ) async {
      int primary = 0;
      String? picked;
      await pumpHost(
        tester,
        (_) => FushiSplitButton(
          label: const Text('Export'),
          icon: const Icon(Icons.ios_share),
          onPressed: () => primary++,
          menuTooltip: 'More',
          menuChildren: <Widget>[
            MenuItemButton(
              onPressed: () => picked = 'csv',
              child: const Text('CSV'),
            ),
            MenuItemButton(
              onPressed: () => picked = 'json',
              child: const Text('JSON'),
            ),
          ],
        ),
      );
      expect(find.byType(FilledButton), findsNWidgets(2));
      await tester.tap(find.text('Export'));
      await tester.pump();
      expect(primary, 1);

      await tester.tap(find.byIcon(FushiIcons.expandMore));
      await advance(tester, 600);
      expect(find.text('CSV'), findsOneWidget);
      final Transform rotation = tester.widget<Transform>(
        find
            .ancestor(
              of: find.byIcon(FushiIcons.expandMore),
              matching: find.byType(Transform),
            )
            .first,
      );
      // 转了约 180°：变换矩阵的 x 轴分量取反。
      expect(rotation.transform.entry(0, 0), closeTo(-1, 0.05));

      // 点菜单外关闭（Esc 关闭由 MenuAnchor 自带）。
      await tester.tapAt(const Offset(4, 4));
      await advance(tester, 600);
      expect(find.text('CSV'), findsNothing);

      await tester.tap(find.byIcon(FushiIcons.expandMore));
      await advance(tester, 600);
      await tester.tap(find.text('JSON'));
      await advance(tester, 600);
      expect(picked, 'json');
    });

    testWidgets('外端全圆、内侧小圆角（S 档内角 4）', (WidgetTester tester) async {
      await pumpHost(
        tester,
        (_) => FushiSplitButton(
          label: const Text('Export'),
          onPressed: () {},
          menuChildren: <Widget>[
            MenuItemButton(onPressed: () {}, child: const Text('CSV')),
          ],
        ),
      );
      final Material lead = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(FilledButton).first,
              matching: find.byType(Material),
            )
            .first,
      );
      final FushiMorphBorder shape = lead.shape! as FushiMorphBorder;
      expect(shape.startPill, 1);
      expect(shape.endPill, 0);
      expect(shape.radius, 4);
    });
  });

  group('FushiFab', () {
    testWidgets('三尺寸边长与圆角，树里仍是 FloatingActionButton', (
      WidgetTester tester,
    ) async {
      for (final (FushiFabSize size, double extent, double radius)
          in <(FushiFabSize, double, double)>[
            (FushiFabSize.regular, 56, 16),
            (FushiFabSize.medium, 80, 20),
            (FushiFabSize.large, 96, 28),
          ]) {
        await pumpHost(
          tester,
          (_) => const SizedBox(),
          fab: FushiFab(
            size: size,
            color: FushiFabColor.tertiaryContainer,
            icon: const Icon(Icons.add),
            onPressed: () {},
          ),
        );
        final Finder fab = find.byType(FloatingActionButton);
        expect(fab, findsOneWidget);
        expect(tester.getSize(fab), Size(extent, extent), reason: '$size');
        final RoundedRectangleBorder shape =
            tester.widget<FloatingActionButton>(fab).shape!
                as RoundedRectangleBorder;
        expect(shape.borderRadius, BorderRadius.circular(radius));
        expect(
          tester
              .widget<Material>(
                find.descendant(of: fab, matching: find.byType(Material)).first,
              )
              .color,
          Theme.of(tester.element(fab)).colorScheme.tertiaryContainer,
        );
      }
    });

    testWidgets('扩展 FAB 带文字', (WidgetTester tester) async {
      await pumpHost(
        tester,
        (_) => const SizedBox(),
        fab: FushiFab(
          icon: const Icon(Icons.add),
          label: const Text('New'),
          onPressed: () {},
        ),
      );
      expect(find.text('New'), findsOneWidget);
      expect(tester.getSize(find.byType(FloatingActionButton)).height, 56);
    });
  });

  group('FushiFabMenu', () {
    testWidgets('点开展开菜单项、点项执行并收起；Esc 收起焦点回 FAB', (WidgetTester tester) async {
      int imported = 0;
      final GlobalKey<FushiFabMenuState> key = GlobalKey<FushiFabMenuState>();
      await pumpHost(
        tester,
        (_) => const SizedBox(),
        fab: FushiFabMenu(
          key: key,
          icon: const Icon(Icons.add),
          tooltip: 'Add',
          closeTooltip: 'Close',
          items: <FushiFabMenuItem>[
            FushiFabMenuItem(
              icon: const Icon(Icons.file_open),
              label: 'Import',
              onPressed: () => imported++,
            ),
            FushiFabMenuItem(
              icon: const Icon(Icons.link),
              label: 'From URL',
              onPressed: () {},
            ),
          ],
        ),
      );
      expect(find.text('Import'), findsNothing);
      await tester.tap(find.byType(FloatingActionButton));
      await advance(tester, 800);
      expect(key.currentState!.isOpen, isTrue);
      expect(find.text('Import'), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
      await tester.tap(find.text('Import'));
      await advance(tester, 800);
      expect(imported, 1);
      expect(key.currentState!.isOpen, isFalse);
      expect(find.text('Import'), findsNothing);

      // 键盘：焦点到 FAB，Enter 展开，焦点进最近的菜单项，Esc 收起回 FAB。
      final FocusNode fabFocus = tester
          .widget<FloatingActionButton>(find.byType(FloatingActionButton))
          .focusNode!;
      fabFocus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await advance(tester, 800);
      expect(key.currentState!.isOpen, isTrue);
      expect(fabFocus.hasFocus, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await advance(tester, 800);
      expect(key.currentState!.isOpen, isFalse);
      expect(fabFocus.hasFocus, isTrue);
    });

    testWidgets('减少动画：瞬间展开（无中间帧）', (WidgetTester tester) async {
      await pumpHost(
        tester,
        (_) => const SizedBox(),
        reduceMotion: true,
        fab: FushiFabMenu(
          icon: const Icon(Icons.add),
          items: <FushiFabMenuItem>[
            FushiFabMenuItem(
              icon: const Icon(Icons.file_open),
              label: 'Import',
              onPressed: () {},
            ),
          ],
        ),
      );
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pump();
      final Opacity opacity = tester.widget<Opacity>(
        find
            .ancestor(of: find.text('Import'), matching: find.byType(Opacity))
            .first,
      );
      expect(opacity.opacity, 1);
    });
  });

  group('FushiSwitch M3E', () {
    testWidgets('MD3 默认带开 / 关 thumb 图标；墨水屏交回主题', (WidgetTester tester) async {
      await pumpHost(
        tester,
        (_) => FushiSwitch(value: false, onChanged: (_) {}),
      );
      final Switch sw = tester.widget<Switch>(find.byType(Switch));
      expect(sw.thumbIcon!.resolve(<WidgetState>{})!.icon, Icons.close_rounded);
      expect(
        sw.thumbIcon!.resolve(<WidgetState>{WidgetState.selected})!.icon,
        Icons.check_rounded,
      );
      await pumpHost(
        tester,
        (_) => FushiSwitch(value: false, onChanged: (_) {}),
        eink: true,
      );
      expect(tester.widget<Switch>(find.byType(Switch)).thumbIcon, isNull);
    });
  });

  group('FushiSlider M3E', () {
    testWidgets('尺寸档改轨道粗细与把手高度；树里仍是 Slider', (WidgetTester tester) async {
      await pumpHost(
        tester,
        (_) => SizedBox(
          width: 300,
          child: FushiSlider(
            value: 0.4,
            size: FushiSliderSize.l,
            onChanged: (_) {},
          ),
        ),
      );
      expect(find.byType(Slider), findsOneWidget);
      final SliderThemeData data = SliderTheme.of(
        tester.element(find.byType(Slider)),
      );
      expect(data.trackHeight, 56);
      expect(data.thumbSize!.resolve(<WidgetState>{}), const Size(4, 68));
    });

    testWidgets('竖直滑块：旋转 90°，方向键上增大', (WidgetTester tester) async {
      double v = 0.5;
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);
      await pumpHost(
        tester,
        (StateSetter setState) => SizedBox(
          height: 240,
          child: FushiSlider(
            value: v,
            divisions: 10,
            axis: Axis.vertical,
            focusNode: node,
            onChanged: (double x) => setState(() => v = x),
          ),
        ),
      );
      expect(find.byType(RotatedBox), findsOneWidget);
      final Size size = tester.getSize(find.byType(RotatedBox));
      expect(size.height, greaterThan(size.width));
      node.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(v, closeTo(0.6, 1e-9));
    });
  });

  group('Icon button L / XL', () {
    testWidgets('XL 136 方形圆角 28', (WidgetTester tester) async {
      await pumpHost(
        tester,
        (_) => FushiIconButtonControl.filled(
          size: FushiIconButtonSize.xl,
          shape: FushiIconButtonShape.square,
          onPressed: () {},
          icon: const Icon(Icons.play_arrow),
        ),
      );
      final Finder material = find
          .descendant(
            of: find.byType(IconButton),
            matching: find.byType(Material),
          )
          .first;
      expect(tester.getSize(material), const Size(136, 136));
      expect(resolvedRadius(tester, material), BorderRadius.circular(28));
    });
  });

  group('chip 强调色', () {
    testWidgets('MD3 选中铺强调色、未选淡色块', (WidgetTester tester) async {
      const Color accent = Color(0xFFE91E63);
      await pumpHost(
        tester,
        (_) => const Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiFilterChip(
              key: ValueKey<String>('on'),
              label: Text('Tag'),
              selected: true,
              accentColor: accent,
              onSelected: null,
            ),
            FushiChoiceChip(
              key: ValueKey<String>('off'),
              label: Text('Tag'),
              selected: false,
              accentColor: accent,
            ),
          ],
        ),
      );
      final ChipThemeData on = ChipTheme.of(
        tester.element(find.byType(FilterChip)),
      );
      expect(on.selectedColor, accent);
      final ChipThemeData off = ChipTheme.of(
        tester.element(find.byType(ChoiceChip)),
      );
      expect(off.backgroundColor, isNot(accent));
      expect(
        off.backgroundColor,
        fushiAccentChipColors(
          accent,
          Theme.of(tester.element(find.byType(ChoiceChip))).colorScheme,
        ).unselected,
      );
    });
  });
}
