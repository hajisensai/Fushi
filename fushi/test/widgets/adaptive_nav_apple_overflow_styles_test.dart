import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/nav_bar_style.dart';
import 'package:fushi/src/utils/adaptive/nav_overflow/nav_dial_bar.dart';
import 'package:fushi/src/utils/adaptive/nav_overflow/nav_mode_strip_bar.dart';
import 'package:fushi/src/utils/adaptive/nav_shape.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:material_ui/material_ui.dart';

// 2026-10-30 用户拍板：Apple（Cupertino）设计系统下「底栏样式」也要真正画出
// 拇指转盘与相机模式条（同一套交互、Apple 视觉），出厂默认同样是相机模式条；
// 平铺保持原样。此前 Apple 胶囊遇到这两种值一律回落「分页滑动」（目的地 ≤5
// 时三种选项完全一样），那条回落路径已删。几何按真手机（390×844、DPR 3、
// 出厂纯图标）。
void main() {
  const Size phone = Size(390, 844);
  const double dpr = 3;

  List<AdaptiveNavItem> itemsOf(int n) => <AdaptiveNavItem>[
    for (int i = 0; i < n; i++)
      AdaptiveNavItem(icon: Icons.circle_outlined, label: 'Tab$i'),
  ];

  Widget app(Widget Function(BuildContext) bar, {bool reduceMotion = false}) {
    return MaterialApp(
      theme: buildFushiThemeData(
        scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        textTheme: Typography.material2021().black,
        // Apple 组件悬浮面实色（glassMaterialTier 钉成 off，2026-10-13 拍板）。
        glass: FushiGlassMaterial.off,
        glassDesign: true,
      ),
      themeAnimationDuration: Duration.zero,
      home: FushiGlassScope(
        child: FushiFocusRoot(
          child: Builder(
            builder: (BuildContext context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: reduceMotion),
              child: Scaffold(
                body: const SizedBox.expand(),
                bottomNavigationBar: Builder(builder: bar),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> pumpBar(
    WidgetTester tester, {
    required AdaptiveNavBarStyle style,
    int count = 9,
    int currentIndex = 0,
    ValueChanged<int>? onTap,
    int? searchIndex,
    bool minimized = false,
    bool reduceMotion = false,
  }) async {
    tester.view.physicalSize = phone * dpr;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
    // 受控组件：与首页外壳一样，onTap 后把新的当前项传回底栏（否则底栏任何一次
    // 重建都会把条带拉回旧的当前项）。
    final ValueNotifier<int> current = ValueNotifier<int>(currentIndex);
    addTearDown(current.dispose);
    await tester.pumpWidget(
      app(
        (BuildContext context) => ValueListenableBuilder<int>(
          valueListenable: current,
          builder: (BuildContext context, int index, Widget? _) =>
              adaptiveBottomBar(
                context: context,
                currentIndex: index,
                onTap: (int i) {
                  current.value = i;
                  onTap?.call(i);
                },
                items: itemsOf(count),
                barStyle: style,
                showLabels: false,
                glassSearchIndex: searchIndex,
                glassMinimized: minimized,
              ),
        ),
        reduceMotion: reduceMotion,
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder target(String id) => find.byWidgetPredicate(
    (Widget w) => w is FushiFocusTarget && w.id == FushiFocusId(id),
  );

  Finder registration(String id) => find.byWidgetPredicate(
    (Widget w) => w is FushiFocusRegistration && w.id == FushiFocusId(id),
  );

  /// M3E 多边形高亮（MD3 专属语汇；Apple 下一个都不该有）。
  Finder polygons() => find.byWidgetPredicate(
    (Widget w) =>
        w is NavMorphShape ||
        (w is DecoratedBox &&
            w.decoration is ShapeDecoration &&
            (w.decoration as ShapeDecoration).shape is MaterialShapeBorder) ||
        (w is Container &&
            w.decoration is ShapeDecoration &&
            (w.decoration as ShapeDecoration).shape is MaterialShapeBorder),
  );

  /// 模式条的 Apple lens（画在 IgnorePointer 里，不按命中测试找）。
  Finder lens() => find.byKey(const ValueKey<String>('nav-mode-strip-lens'));

  /// lens 此刻是否画出来（墨滴流动中由墨滴代画、lens 隐藏）。
  bool lensShown(WidgetTester tester) => tester
      .widget<Visibility>(
        find.ancestor(of: lens(), matching: find.byType(Visibility)).first,
      )
      .visible;

  test('出厂默认（没写过偏好）是相机模式条，不分设计系统', () {
    expect(AdaptiveNavBarStyle.fromPref(''), AdaptiveNavBarStyle.modeStrip);
    expect(AdaptiveNavBarStyle.defaultStyle, AdaptiveNavBarStyle.modeStrip);
  });

  testWidgets('Apple 出厂默认样式画的是相机模式条：Apple lens、无 M3E 多边形', (
    WidgetTester tester,
  ) async {
    await pumpBar(tester, style: AdaptiveNavBarStyle.fromPref(''));
    expect(isGlassDesign(tester.element(find.byType(Scaffold))), isTrue);
    expect(find.byType(NavModeStripBar), findsOneWidget);
    expect(find.byType(NavDialBar), findsNothing);
    expect(lens(), findsOneWidget, reason: '当前项背后是圆形 Apple lens');
    expect(lensShown(tester), isTrue);
    expect(polygons(), findsNothing, reason: 'Apple 不画 M3E 多边形');
    // 9 个目的地都在条带里（放不下的横拨），每一项都是独立焦点目标。
    for (int i = 0; i < 9; i++) {
      expect(target('nav-bar-$i'), findsOneWidget);
    }
  });

  testWidgets('目的地不多于 5 个时三种样式确实不同（不再都是同一排）', (WidgetTester tester) async {
    await pumpBar(tester, style: AdaptiveNavBarStyle.flat, count: 5);
    expect(find.byType(NavModeStripBar), findsNothing);
    expect(find.byType(NavDialBar), findsNothing);
    await pumpBar(tester, style: AdaptiveNavBarStyle.modeStrip, count: 5);
    expect(find.byType(NavModeStripBar), findsOneWidget);
    await pumpBar(tester, style: AdaptiveNavBarStyle.dial, count: 5);
    expect(find.byType(NavDialBar), findsOneWidget);
  });

  testWidgets('Apple 平铺保持原样：9 个目的地一排平铺，不画原型', (WidgetTester tester) async {
    await pumpBar(tester, style: AdaptiveNavBarStyle.flat);
    expect(find.byType(NavModeStripBar), findsNothing);
    expect(find.byType(NavDialBar), findsNothing);
    for (int i = 0; i < 9; i++) {
      expect(target('nav-bar-$i').hitTestable(), findsOneWidget);
    }
  });

  testWidgets('Apple 相机模式条：点邻居切过去，横拨跟手切换，走 onTap', (WidgetTester tester) async {
    final List<int> taps = <int>[];
    await pumpBar(
      tester,
      style: AdaptiveNavBarStyle.modeStrip,
      onTap: taps.add,
    );
    await tester.tap(target('nav-bar-2'));
    await tester.pumpAndSettle();
    expect(taps, <int>[2]);
    // 往左拨两格（10px 一步跟手）：从 2 到 4。格宽随胶囊宽与目的地数变，按实测
    // 相邻两格中心距算，不写死像素。
    final double slot =
        tester.getCenter(target('nav-bar-3')).dx -
        tester.getCenter(target('nav-bar-2')).dx;
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(target('nav-bar-2')),
    );
    for (int i = 0; i < (slot * 2 / 10).round(); i++) {
      await gesture.moveBy(const Offset(-10, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(taps, <int>[2, 4]);
  });

  testWidgets('Apple 相机模式条：手柄方向键走遍全部目的地，藏着的项滚进胶囊，Enter 切过去', (
    WidgetTester tester,
  ) async {
    final List<int> taps = <int>[];
    await pumpBar(
      tester,
      style: AdaptiveNavBarStyle.modeStrip,
      onTap: taps.add,
    );
    final FushiFocusController focus = FushiFocusRoot.controllerOf(
      tester.element(target('nav-bar-0')),
    );
    expect(focus.requestById(const FushiFocusId('nav-bar-0')), isTrue);
    await tester.pumpAndSettle();
    String? primary() => FocusManager.instance.primaryFocus?.debugLabel;
    for (int i = 1; i < 9; i++) {
      expect(focus.move(FushiFocusDirection.right), isTrue, reason: '→ $i');
      await tester.pumpAndSettle();
      expect(primary(), 'nav-bar-$i');
      final double x = tester.getCenter(target('nav-bar-$i')).dx;
      expect(x, inInclusiveRange(0, phone.width), reason: '焦点格滚进可见区');
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(taps, <int>[8]);
  });

  testWidgets('Apple 相机模式条：无障碍语义报原文案、当前项 selected', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await pumpBar(
      tester,
      style: AdaptiveNavBarStyle.modeStrip,
      currentIndex: 1,
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Tab1')),
      containsSemantics(
        label: 'Tab1',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        hasTapAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Tab3')),
      containsSemantics(
        label: 'Tab3',
        isButton: true,
        isSelected: false,
        hasSelectedState: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('Apple 相机模式条：减弱动态效果下高亮直接落位，不播墨滴', (WidgetTester tester) async {
    await pumpBar(
      tester,
      style: AdaptiveNavBarStyle.modeStrip,
      reduceMotion: true,
    );
    await tester.tap(target('nav-bar-3'));
    await tester.pump();
    // 一帧之内 lens 已落在新位置（有动效时这一帧还在播墨滴、lens 隐藏）。
    expect(lensShown(tester), isTrue, reason: '没有墨滴流动');
    expect(
      tester.getCenter(lens()).dx,
      moreOrLessEquals(tester.getCenter(target('nav-bar-3')).dx, epsilon: 1),
    );
  });

  testWidgets('Apple 相机模式条：下滑最小化成圆，只剩当前项', (WidgetTester tester) async {
    await pumpBar(
      tester,
      style: AdaptiveNavBarStyle.modeStrip,
      currentIndex: 2,
      minimized: true,
    );
    expect(find.byType(NavModeStripBar), findsNothing);
    expect(target('nav-mini-bar').hitTestable(), findsOneWidget);
  });

  testWidgets('Apple 相机模式条：查词仍是胶囊右侧圆钮，不进条带', (WidgetTester tester) async {
    await pumpBar(tester, style: AdaptiveNavBarStyle.modeStrip, searchIndex: 6);
    expect(target('nav-bar-6').hitTestable(), findsOneWidget);
    final double lookupX = tester.getCenter(target('nav-bar-6')).dx;
    expect(lookupX, greaterThan(phone.width - 62));
    final NavModeStripBar strip = tester.widget(find.byType(NavModeStripBar));
    expect(strip.spec.indices, isNot(contains(6)));
  });

  testWidgets('Apple 拇指转盘：固定格 + 旋钮，按旋钮升起转盘，Apple 圆形高亮、无 M3E 多边形', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await pumpBar(tester, style: AdaptiveNavBarStyle.dial);
    expect(find.byType(NavDialBar), findsOneWidget);
    expect(find.byType(NavModeStripBar), findsNothing);
    // 胶囊里平铺放得下的固定格（标准焦点格），最后是登记成焦点目标的旋钮。
    expect(target('nav-bar-0').hitTestable(), findsOneWidget);
    expect(registration('nav-bar-dial'), findsOneWidget);
    expect(polygons(), findsNothing);

    expect(find.bySemanticsLabel('Tab8'), findsNothing, reason: '收起时藏在转盘里');
    await tester.tap(registration('nav-bar-dial'));
    await tester.pumpAndSettle();
    // 转盘升起：藏着的目的地出现在转盘上。
    expect(find.bySemanticsLabel('Tab8'), findsWidgets);
    expect(polygons(), findsNothing, reason: '转盘上也只画圆');
    handle.dispose();
  });

  testWidgets('Apple 拇指转盘：手柄从固定格走到旋钮，Enter 打开、方向键转、Enter 跳转', (
    WidgetTester tester,
  ) async {
    final List<int> taps = <int>[];
    await pumpBar(tester, style: AdaptiveNavBarStyle.dial, onTap: taps.add);
    final FushiFocusController focus = FushiFocusRoot.controllerOf(
      tester.element(target('nav-bar-0')),
    );
    expect(focus.requestById(const FushiFocusId('nav-bar-dial')), isTrue);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'NavDialBar.knob');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(taps, <int>[1]);
  });
}
