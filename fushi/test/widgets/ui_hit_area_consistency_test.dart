import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_kit.dart';
import 'package:fushi/src/utils/components/fushi_pill_segmented_button.dart';
import 'package:fushi/src/utils/components/fushi_fill_slot.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_scroll_chrome.dart';
import 'package:fushi/src/utils/settled_theme.dart';
import 'package:fushi/utils.dart';

/// 2026-10-09 用户「按钮的悬停 / 按下反馈与可点范围要和可见形状完全一致，全 app
/// 统一，可以选满」：反馈页刷新键、词典管理返回键悬停只亮中间一枚更小的圆 /
/// 方块；书架页签悬停胶囊、选中胶囊、可点区域三者不一致。
///
/// 这里钉住共享组件层的不变式：**可见容器 = ink 区 = 命中区**。
Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

/// [root] 子树里唯一一个 InkWell 的 RenderBox 尺寸。
Size _inkSize(WidgetTester tester, Finder root) {
  final Finder ink = find.descendant(
    of: root,
    matching: find.byWidgetPredicate((Widget w) => w is InkWell),
  );
  expect(ink, findsOneWidget);
  return tester.getSize(ink);
}

/// 在 [root] 中心偏 [offset] 处点一下。
Future<void> _tapAt(WidgetTester tester, Finder root, Offset offset) async {
  await tester.tapAt(tester.getCenter(root) + offset);
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUp(() => LocaleSettings.setLocaleRaw('zh-CN'));
  tearDown(() => LocaleSettings.setLocaleRaw('en'));

  group('圆形页头胶囊（返回 / 单个动作）：ink 与命中区撑满整枚圆', () {
    testWidgets('FushiIconButtonControl', (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(
        _host(
          FushiPageChromeCircle(
            child: FushiIconButtonControl(
              icon: const Icon(Icons.arrow_back),
              tooltip: 'back',
              onPressed: () => taps++,
            ),
          ),
        ),
      );
      final Finder circle = find.byType(FushiPageChromeCircle);
      expect(tester.getSize(circle), const Size.square(kFushiPageChromeExtent));
      expect(_inkSize(tester, circle), tester.getSize(circle));
      final InkWell ink = tester.widget<InkWell>(
        find.descendant(of: circle, matching: find.byType(InkWell)),
      );
      expect(ink.customBorder, isA<CircleBorder>());
      // 圆的边缘内侧（旧实现 40 的按钮外、56 的圆内）也能点中。
      await _tapAt(tester, circle, const Offset(0, 25));
      await _tapAt(tester, circle, const Offset(-25, 0));
      expect(taps, 2);
    });

    testWidgets('FushiIconButton', (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(
        _host(
          FushiPageChromeCircle(
            child: FushiIconButton(
              icon: Icons.refresh,
              tooltip: 'refresh',
              onTap: () => taps++,
            ),
          ),
        ),
      );
      final Finder circle = find.byType(FushiPageChromeCircle);
      expect(_inkSize(tester, circle), tester.getSize(circle));
      final InkWell ink = tester.widget<InkWell>(
        find.descendant(of: circle, matching: find.byType(InkWell)),
      );
      expect(ink.customBorder, isA<CircleBorder>());
      await _tapAt(tester, circle, const Offset(25, 0));
      expect(taps, 1);
    });

    testWidgets('框架 IconButton（经 IconButtonTheme）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _host(
          FushiPageChromeCircle(
            child: IconButton(icon: const Icon(Icons.close), onPressed: () {}),
          ),
        ),
      );
      final Finder circle = find.byType(FushiPageChromeCircle);
      expect(_inkSize(tester, circle), tester.getSize(circle));
    });
  });

  testWidgets('页头动作区只有一颗图标按钮时画成圆胶囊（不再是胶囊里一枚小按钮）', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        fushiFloatingHeaderActionGroups(<Widget>[
          FushiIconButton(
            icon: Icons.refresh,
            tooltip: 'refresh',
            onTap: () {},
          ),
        ], (List<Widget> icons) => Row(children: icons)),
      ),
    );
    final Finder circle = find.byType(FushiPageChromeCircle);
    expect(circle, findsOneWidget);
    expect(_inkSize(tester, circle), tester.getSize(circle));
  });

  testWidgets('FushiFloatingTopBar 返回键：ink = 圆胶囊', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 600,
          child: FushiFloatingTopBar(
            leading: <FushiToolbarItem>[
              FushiToolbarItem(
                icon: Icons.arrow_back,
                label: 'Back',
                onPressed: () {},
              ),
            ],
            title: '词典管理',
          ),
        ),
      ),
    );
    final Finder slot = find.byType(FushiFillSlot);
    expect(slot, findsOneWidget);
    expect(tester.getSize(slot), const Size.square(56));
    expect(_inkSize(tester, slot), const Size.square(56));
  });

  testWidgets('单按钮悬浮工具栏塌成一枚圆，按钮撑满', (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(
      _host(
        FushiFloatingToolbar(
          compact: true,
          groups: <List<FushiToolbarItem>>[
            <FushiToolbarItem>[
              FushiToolbarItem(
                icon: Icons.refresh,
                label: 'Refresh',
                onPressed: () => taps++,
              ),
            ],
          ],
        ),
      ),
    );
    final Finder bar = find.byKey(
      const ValueKey<String>('fushi_floating_toolbar'),
    );
    expect(tester.getSize(bar), const Size.square(56));
    expect(_inkSize(tester, bar), const Size.square(56));
    await _tapAt(tester, bar, const Offset(0, -25));
    expect(taps, 1);
  });

  testWidgets('浮动分区页签：选中胶囊 = 整格 = ink 区（不再上下各缩 4）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: LibrarySectionTabs<int>(
              floating: true,
              tabs: const <LibrarySectionTab<int>>[
                LibrarySectionTab<int>(value: 0, label: '书架'),
                LibrarySectionTab<int>(value: 1, label: '来源'),
                LibrarySectionTab<int>(value: 2, label: '设置'),
              ],
              selected: 1,
              onChanged: (int _) {},
              focusIdPrefix: 'hit-area-test',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final TabBar bar = tester.widget<TabBar>(find.byType(TabBar));
    expect(bar.indicatorPadding, EdgeInsets.zero);
    expect(bar.indicatorSize, TabBarIndicatorSize.tab);
    final double barHeight = tester.getSize(find.byType(TabBar)).height;
    final Finder tabInk = find.ancestor(
      of: find.text('来源'),
      matching: find.byType(InkWell),
    );
    expect(
      tabInk.evaluate().any(
        (Element e) => (e.renderObject! as RenderBox).size.height == barHeight,
      ),
      isTrue,
      reason: '页签的 ink 区高度必须等于整条页签（= 选中胶囊高度）',
    );
  });

  group('设置分类图标色调', () {
    test('分类图标不用 red（error 容器不随主题变色，只留给破坏性行）', () {
      for (final SettingsDestinationId id in SettingsDestinationId.values) {
        expect(
          settingsIconToneFor(id),
          isNot(SettingsIconTone.red),
          reason: '$id 用了 red：换主题时只有它还是红的',
        );
      }
    });
  });

  group('设置滑条拖动跟手', () {
    testWidgets('调用方拖动中不写回 value，滑块仍跟手；松手后交还', (WidgetTester tester) async {
      final List<double> changes = <double>[];
      double? ended;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 500,
                child: AdaptiveSettingsSliderRow(
                  title: '字号',
                  value: 12,
                  min: 12,
                  max: 48,
                  divisions: 36,
                  // 字幕外观滑条的形态：拖动中只预览，不把新值写回 value。
                  onChanged: changes.add,
                  onChangeEnd: (double v) => ended = v,
                ),
              ),
            ),
          ),
        ),
      );
      final Finder slider = find.byType(Slider);
      expect(tester.widget<Slider>(slider).value, 12);
      final TestGesture gesture = await tester.startGesture(
        tester.getTopLeft(slider) + const Offset(30, 24),
      );
      await gesture.moveBy(const Offset(200, 0));
      await tester.pump();
      expect(changes, isNotEmpty);
      expect(
        tester.widget<Slider>(slider).value,
        greaterThan(12),
        reason: '拖动中滑块必须跟手，不能钉在调用方的旧值上',
      );
      await gesture.up();
      await tester.pump();
      expect(ended, isNotNull);
    });
  });

  test('词典弹窗：没有注音的词头不背注音预留（顶栏与词头之间不再空一行）', () {
    final String css = File('assets/popup/popup.css').readAsStringSync();
    final RegExp rule = RegExp(
      r'\.expression:not\(:has\(rt\)\)\s*\{[^}]*padding-top:\s*0;',
    );
    expect(rule.hasMatch(css), isTrue);
    // 有注音时预留照旧（BUG-1098 / BUG-2568 的裁切防线）。
    expect(
      RegExp(r'\.expression\s*\{[^}]*padding-top:\s*0\.66em;').hasMatch(css),
      isTrue,
    );
  });

  group('主题过渡：原生窗口只认目标主题', () {
    final ThemeData light = ThemeData(brightness: Brightness.light);
    final ThemeData dark = ThemeData(brightness: Brightness.dark);
    test('fushiSettledTheme 按 themeMode / 平台明暗选目标主题', () {
      ThemeData pick(ThemeMode mode, Brightness platform) => fushiSettledTheme(
        themeMode: mode,
        platformBrightness: platform,
        light: light,
        dark: dark,
      );
      expect(pick(ThemeMode.light, Brightness.dark), same(light));
      expect(pick(ThemeMode.dark, Brightness.light), same(dark));
      expect(pick(ThemeMode.system, Brightness.dark), same(dark));
      expect(pick(ThemeMode.system, Brightness.light), same(light));
    });
  });

  testWidgets('Apple 顶栏 scroll edge：带 bandExtent 时栏区实色、只有内沿是渐隐带', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 300,
              height: 120,
              child: FushiAppleScrollEdge(
                side: FushiScrollEdgeSide.top,
                visible: true,
                blur: false,
                bandExtent: 20,
              ),
            ),
          ),
        ),
      ),
    );
    final Finder fill = find.descendant(
      of: find.byType(FushiAppleScrollEdge),
      matching: find.byType(ColoredBox),
    );
    expect(fill, findsOneWidget);
    expect(tester.getSize(fill), const Size(300, 100));
    expect(
      tester.getTopLeft(fill).dy,
      tester.getTopLeft(find.byType(FushiAppleScrollEdge)).dy,
    );
    // 实色区与渐隐带最靠边处同色同不透明度：无接缝。
    expect(tester.widget<ColoredBox>(fill).color.a, 1);
  });

  test('Apple 顶栏把 scroll edge 铺满整段栏区（不再只贴在栏下沿）', () {
    final String src = File(
      'lib/src/utils/components/glass/fushi_glass_bars.dart',
    ).readAsStringSync();
    final int at = src.indexOf('class _AppleBarScrollEdgeState');
    final String body = src.substring(at, src.indexOf('\nclass ', at + 10));
    expect(body, contains('top: 0,'));
    expect(body, contains('bandExtent: _kGlassTopEdgeExtent'));
  });

  testWidgets('设置页头：返回 / 标题 / 动作三块胶囊同高、块间留距', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 600,
          child: SettingsFloatingHeader(
            title: '外观与交互',
            subtitle: '界面',
            onBack: () {},
            actions: <Widget>[
              FushiIconButton(
                icon: Icons.more_vert,
                tooltip: 'more',
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Finder slots = find.byType(FushiFillSlot);
    expect(slots, findsNWidgets(2), reason: '返回键与单个动作都是撑满的圆胶囊');
    final Rect back = tester.getRect(slots.first);
    final Rect more = tester.getRect(slots.last);
    expect(back.size, const Size.square(kFushiFloatingToolbarCompactExtent));
    expect(more.size, const Size.square(kFushiFloatingToolbarCompactExtent));
    final Rect title = tester.getRect(
      find
          .ancestor(
            of: find.text('外观与交互'),
            matching: find.byWidgetPredicate(
              (Widget w) =>
                  w is ConstrainedBox &&
                  w.constraints.minHeight == kFushiFloatingToolbarCompactExtent,
            ),
          )
          .first,
    );
    expect(title.height, kFushiFloatingToolbarCompactExtent);
    expect(
      more.left - title.right,
      greaterThanOrEqualTo(4),
      reason: '标题胶囊与动作胶囊不能贴在一起',
    );
  });

  testWidgets('Material 分段选择器：胶囊轨道 + 选中胶囊，ink = 选中胶囊同形同大', (
    WidgetTester tester,
  ) async {
    int? picked;
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (BuildContext context) => adaptiveSegmentedButton<int>(
            context: context,
            segments: const <ButtonSegment<int>>[
              ButtonSegment<int>(value: 0, icon: Icon(Icons.light_mode)),
              ButtonSegment<int>(value: 1, icon: Icon(Icons.brightness_auto)),
              ButtonSegment<int>(value: 2, icon: Icon(Icons.dark_mode)),
            ],
            selected: const <int>{1},
            onSelectionChanged: (Set<int> v) => picked = v.single,
          ),
        ),
      ),
    );
    expect(find.byType(FushiPillSegmentedButton<int>), findsOneWidget);
    final Finder inks = find.descendant(
      of: find.byType(FushiPillSegmentedButton<int>),
      matching: find.byType(InkWell),
    );
    expect(inks, findsNWidgets(3));
    final Set<Size> sizes = <Size>{
      for (final Element e in inks.evaluate())
        (e.renderObject! as RenderBox).size,
    };
    expect(sizes, hasLength(1), reason: '各段等宽等高');
    expect(sizes.single.height, FushiPillSegmentedButton.segmentHeight);
    for (final Element e in inks.evaluate()) {
      expect((e.widget as InkWell).customBorder, isA<StadiumBorder>());
    }
    await tester.tap(find.byIcon(Icons.dark_mode));
    expect(picked, 2);
  });

  test('设置详情 / 窄屏设置页：页头背后的遮罩实色盖满让位高度', () {
    final String kit = File(
      'lib/src/settings/settings_kit.dart',
    ).readAsStringSync();
    expect(kit, contains('solidHeight: inset(),'));
    final String home = File(
      'lib/src/settings/settings_home_page.dart',
    ).readAsStringSync();
    expect(home, contains('solidHeight: _narrowHeaderHeight.value,'));
  });

  test('串流游戏库作为外壳顶层 tab 时让开外壳标题胶囊', () {
    final String src = File(
      'lib/src/pages/implementations/game_stream_library_page.dart',
    ).readAsStringSync();
    expect(src, contains('body: FushiFloatingChromeVisiblePadding('));
  });
}
