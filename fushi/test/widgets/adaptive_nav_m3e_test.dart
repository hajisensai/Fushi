import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/adaptive/nav_shape.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart'
    show kFushiFloatingCapsuleScale;
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

// 2026-10-05 用户：「导航栏和侧边栏也统一成 m3e」。
//
// MD3 设计系统的应用级导航按 M3 Expressive 规格：
// - 宽屏 navigation rail 有收起（96）/ 展开（220，取代旧侧边抽屉）两态，顶部
//   菜单钮切换，宽度走 spatial 弹簧；展开态恒显示文字标签，收起态纯图标
//   （2026-10-23 用户「侧边栏收起不显示文字」，PR #2476 的 M3E 侧栏），名称
//   进 tooltip 与无障碍语义；
// - 底栏（flexible navigation bar）64 高、标签恒显示（首页 ≥600 走 rail，
//   M3E 的横排目的地不在底栏里做）；
// - 活动指示器选中时按 expressive 弹簧展开，悬停 / 按压状态层与指示器同框；
// - 菜单钮是独立焦点目标，键盘 / 手柄能走到并用 Enter 切换。
void main() {
  const List<AdaptiveNavItem> items = <AdaptiveNavItem>[
    AdaptiveNavItem(
      icon: Icons.home_outlined,
      selectedIcon: Icons.home,
      label: '首页',
    ),
    AdaptiveNavItem(icon: Icons.menu_book_outlined, label: '书架'),
    AdaptiveNavItem(icon: Icons.movie_outlined, label: '视频'),
    AdaptiveNavItem(icon: Icons.tune_outlined, label: '设置'),
  ];

  /// 带菜单钮的 rail：菜单钮翻转 [expanded]，记录切换次数。
  Future<ValueNotifier<bool>> pumpToggleRail(
    WidgetTester tester, {
    bool initiallyExpanded = false,
    bool reduceMotion = false,
  }) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ValueNotifier<bool> expanded = ValueNotifier<bool>(initiallyExpanded);
    addTearDown(expanded.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(1200, 800),
            disableAnimations: reduceMotion,
          ),
          child: FushiFocusRoot(
            child: Scaffold(
              body: Row(
                children: <Widget>[
                  ValueListenableBuilder<bool>(
                    valueListenable: expanded,
                    builder: (BuildContext context, bool value, _) =>
                        adaptiveNavRail(
                          context: context,
                          currentIndex: 1,
                          onTap: (_) {},
                          items: items,
                          extended: value,
                          onToggleExtended: () =>
                              expanded.value = !expanded.value,
                        ),
                  ),
                  const Expanded(child: SizedBox.expand()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return expanded;
  }

  /// 悬浮侧轨面板宽（占位宽扣掉左右留白）。
  double railWidth(WidgetTester tester) =>
      tester.getSize(find.byKey(fushiMaterialNavKey)).width -
      kMaterialNavRailFloatingInset;

  // 只认能点到的那份：MD3 悬浮底栏常驻挂着一枚透明 + IgnorePointer 的
  // 「最小化小胶囊」，里面是当前项的图标与标签（690c4905896），不是可见目的地。
  bool labelPainted(WidgetTester tester, String label) {
    final Finder text = find.text(label).hitTestable();
    if (text.evaluate().length != 1) return false;
    final Size size = tester.getSize(text);
    return size.width > 0 && size.height > 0;
  }

  group('M3E navigation rail', () {
    testWidgets('菜单钮在收起 96 / 展开 220 两态之间切换，宽度按弹簧过渡', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<bool> expanded = await pumpToggleRail(tester);
      expect(railWidth(tester), kMaterialNavRailCollapsedWidth);
      expect(find.byIcon(FushiIcons.menu), findsOneWidget);
      expect(find.byTooltip('Expand navigation'), findsOneWidget);

      await tester.tap(find.byIcon(FushiIcons.menu));
      await tester.pump();
      expect(expanded.value, isTrue);
      await tester.pump(const Duration(milliseconds: 30));
      final double mid = railWidth(tester);
      expect(mid, greaterThan(kMaterialNavRailCollapsedWidth));
      expect(mid, lessThan(kMaterialNavRailExpandedWidth));
      expect(tester.takeException(), isNull, reason: '过渡中展开行不应溢出');

      await tester.pumpAndSettle();
      expect(railWidth(tester), kMaterialNavRailExpandedWidth);
      expect(find.byIcon(FushiIcons.menuOpen), findsOneWidget);
      expect(find.byTooltip('Collapse navigation'), findsOneWidget);

      await tester.tap(find.byIcon(FushiIcons.menuOpen));
      await tester.pumpAndSettle();
      expect(expanded.value, isFalse);
      expect(railWidth(tester), kMaterialNavRailCollapsedWidth);
      expect(tester.takeException(), isNull);
    });

    testWidgets('收起态纯图标、名称进 tooltip 与语义；展开态恒显示全部文字标签', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final ValueNotifier<bool> expanded = await pumpToggleRail(tester);
      for (final AdaptiveNavItem item in items) {
        expect(
          find.text(item.label),
          findsNothing,
          reason: '${item.label}：收起态不画文字',
        );
        expect(find.byIcon(item.icon), findsOneWidget, reason: item.label);
        // 收起格的 tooltip 不进语义（名称由外层 Semantics 报），flutter_test 的
        // byTooltip 只认 SDK 旧 Tooltip 类型，这里直接按 material_ui 的 Tooltip 找。
        expect(
          find.byWidgetPredicate(
            (Widget w) => w is Tooltip && w.message == item.label,
          ),
          findsOneWidget,
          reason: '${item.label}：名称要进 tooltip',
        );
        expect(
          find.bySemanticsLabel(item.label),
          findsOneWidget,
          reason: '${item.label}：名称仍要进无障碍语义',
        );
      }
      expanded.value = true;
      await tester.pumpAndSettle();
      for (final AdaptiveNavItem item in items) {
        expect(labelPainted(tester, item.label), isTrue, reason: item.label);
      }
      // 展开态图标与标签横排（同一水平线、图标在前）。
      final Rect icon = tester.getRect(find.byIcon(Icons.movie_outlined));
      final Rect label = tester.getRect(find.text('视频'));
      expect(icon.right, lessThan(label.left));
      expect((icon.center.dy - label.center.dy).abs(), lessThan(2));
      semantics.dispose();
    });

    testWidgets('减弱动态效果下宽度同帧到位', (WidgetTester tester) async {
      final ValueNotifier<bool> expanded = await pumpToggleRail(
        tester,
        reduceMotion: true,
      );
      expanded.value = true;
      await tester.pump();
      expect(railWidth(tester), kMaterialNavRailExpandedWidth);
    });

    testWidgets('不传 onToggleExtended 时不画菜单钮', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: FushiFocusRoot(
            child: Scaffold(
              body: Row(
                children: <Widget>[
                  Builder(
                    builder: (BuildContext context) => adaptiveNavRail(
                      context: context,
                      currentIndex: 0,
                      onTap: (_) {},
                      items: items,
                      extended: false,
                    ),
                  ),
                  const Expanded(child: SizedBox.expand()),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(FushiIcons.menu), findsNothing);
      expect(railWidth(tester), kMaterialNavRailCollapsedWidth);
    });

    testWidgets('菜单钮是独立焦点目标：从首个目的地向上可达，Enter 切换', (WidgetTester tester) async {
      final ValueNotifier<bool> expanded = await pumpToggleRail(tester);
      final FushiFocusController controller = FushiFocusRoot.controllerOf(
        tester.element(find.byKey(fushiMaterialNavKey)),
      );
      expect(controller.requestById(const FushiFocusId('nav-rail-0')), isTrue);
      await tester.pump();
      expect(controller.move(FushiFocusDirection.up), isTrue);
      await tester.pump();
      expect(controller.activeId, const FushiFocusId('nav-rail-menu'));
      expect(expanded.value, isFalse, reason: '焦点落上菜单钮不应切换');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(expanded.value, isTrue);
      expect(railWidth(tester), kMaterialNavRailExpandedWidth);

      // 展开后向下回到目的地，焦点仍按目的地遍历。
      expect(controller.move(FushiFocusDirection.down), isTrue);
      await tester.pump();
      expect(controller.activeId!.value, startsWith('nav-rail-'));
      expect(controller.activeId, isNot(const FushiFocusId('nav-rail-menu')));
    });

    testWidgets('展开态菜单钮的状态层与药丸同为全圆角胶囊', (WidgetTester tester) async {
      await pumpToggleRail(tester, initiallyExpanded: true);
      final InkWell menuInk = tester.widget<InkWell>(
        find
            .ancestor(
              of: find.byIcon(FushiIcons.menuOpen),
              matching: find.byWidgetPredicate((Widget w) => w is InkWell),
            )
            .first,
      );
      final Size menu = tester.getSize(
        find
            .ancestor(
              of: find.byIcon(FushiIcons.menuOpen),
              matching: find.byWidgetPredicate((Widget w) => w is InkWell),
            )
            .first,
      );
      expect(menuInk.borderRadius, BorderRadius.circular(menu.height / 2));
    });
  });

  group('adaptiveNavRailExtended', () {
    testWidgets('MD3：没切过按尺寸档，切过按用户选择', (WidgetTester tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) {
              ctx = context;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(
        adaptiveNavRailExtended(ctx, sizeClass: WindowSizeClass.expanded),
        isTrue,
      );
      expect(
        adaptiveNavRailExtended(ctx, sizeClass: WindowSizeClass.medium),
        isFalse,
      );
      expect(
        adaptiveNavRailExtended(
          ctx,
          sizeClass: WindowSizeClass.expanded,
          userExpanded: false,
        ),
        isFalse,
      );
      expect(
        adaptiveNavRailExtended(
          ctx,
          sizeClass: WindowSizeClass.medium,
          userExpanded: true,
        ),
        isTrue,
      );
      expect(
        adaptiveNavRailWidthFor(ctx, extended: false),
        kMaterialNavRailCollapsedWidth + kMaterialNavRailFloatingInset,
      );
      expect(
        adaptiveNavRailWidthFor(ctx, extended: true),
        kMaterialNavRailExpandedWidth + kMaterialNavRailFloatingInset,
      );
    });
  });

  group('M3E flexible navigation bar', () {
    Future<void> pumpBar(
      WidgetTester tester, {
      required double width,
      int currentIndex = 2,
      ValueChanged<int>? onTap,
    }) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: FushiFocusRoot(
            child: Scaffold(
              body: const SizedBox.expand(),
              bottomNavigationBar: Builder(
                builder: (BuildContext context) => adaptiveBottomBar(
                  context: context,
                  currentIndex: currentIndex,
                  onTap: onTap ?? (_) {},
                  items: items,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Rect stateLayerRect(WidgetTester tester, String label) {
      final Finder ink = find
          .ancestor(
            of: find.text(label).hitTestable(),
            matching: find.byWidgetPredicate((Widget w) => w is InkWell),
          )
          .first;
      final InkWell inkWell = tester.widget<InkWell>(ink);
      final RenderBox ref = tester.renderObject<RenderBox>(ink);
      final RectCallback? callback = inkWell.getRectCallback(ref);
      final Rect local = callback == null ? Offset.zero & ref.size : callback();
      // 经完整祖先变换换成屏幕框：Material 浮动底栏整体按
      // [kFushiFloatingCapsuleScale] 缩放，只平移 localToGlobal(Offset.zero)
      // 会得到「局部尺寸 + 屏幕原点」的混合框。
      return MatrixUtils.transformRect(ref.getTransformTo(null), local);
    }

    testWidgets('手机宽：竖排目的地、按标签行高精确适配、全部标签可见', (WidgetTester tester) async {
      await pumpBar(tester, width: 420);
      // 胶囊高 = max(64, 选中多边形 40 + 缝 2 + 标签实际行高 + 上下留白)（fb665edc33a：
      // 按标签行高撑开，免得标签下半截被圆角裁掉），不再是恒 64。
      final Rect bar = tester.getRect(find.byKey(fushiMaterialNavKey));
      final double capsule =
          bar.height -
          kAdaptiveNavBarFloatingTopGap -
          kAdaptiveNavFloatingMargin;
      // 64 是下限而非唯一尺寸，但不能只断言 >= 64：任意多出的空白也会假绿。
      // fb665edc33a 的几何契约：上下各 10、多边形槽 40、间隔 2、真实标签行高，
      // 向上取整后至少 64；字体度量来自当前宿主，不能按此次 CI 的 88 硬编码。
      final BuildContext barContext = tester.element(
        find.byKey(fushiMaterialNavKey),
      );
      final TextStyle labelStyle =
          (Theme.of(barContext).textTheme.labelMedium ?? const TextStyle())
              .copyWith(fontSize: 12, fontWeight: FontWeight.w600);
      final TextPainter labelMeasure = TextPainter(
        text: TextSpan(text: 'Ag国', style: labelStyle),
        textDirection: Directionality.of(barContext),
        textScaler: MediaQuery.textScalerOf(
          barContext,
        ).clamp(maxScaleFactor: 1.3),
        maxLines: 1,
      )..layout();
      final double labelHeight = labelMeasure.height;
      labelMeasure.dispose();
      const double verticalPadding = 10;
      const double shapeSlot = 40;
      const double labelGap = 2;
      final double expectedCapsule = math.max(
        kAdaptiveNavBarContentHeight,
        (2 * verticalPadding + shapeSlot + labelGap + labelHeight)
            .ceilToDouble(),
      );
      // 上面是胶囊自身坐标里的几何；Material 浮动底栏整体按
      // [kFushiFloatingCapsuleScale] 缩放（FushiCapsuleScale），屏幕上量到的
      // 胶囊高 = 局部高 × 缩放（上下 gap / margin 在缩放层外面，不缩）。
      expect(
        capsule,
        closeTo(expectedCapsule * kFushiFloatingCapsuleScale, 1e-6),
        reason: '胶囊只为标签行高让位，不得凭空增加高度',
      );
      for (final AdaptiveNavItem item in items) {
        expect(labelPainted(tester, item.label), isTrue, reason: item.label);
        final Rect icon = tester.getRect(find.byIcon(item.icon).hitTestable());
        final Rect label = tester.getRect(find.text(item.label).hitTestable());
        expect(icon.bottom, lessThanOrEqualTo(label.top), reason: '图标在上');
        expect(
          icon.top,
          greaterThanOrEqualTo(bar.top + kAdaptiveNavBarFloatingTopGap),
          reason: '${item.label} 图标落在胶囊里',
        );
        expect(
          label.bottom,
          lessThanOrEqualTo(bar.bottom - kAdaptiveNavFloatingMargin),
          reason: '${item.label} 标签完整落在胶囊里',
        );
      }
      // 悬停 / 按压状态层与选中多边形同框（带标签时 40 的方槽，圆形裁剪）。
      // 40 是胶囊自身坐标里的槽；屏幕上同乘胶囊缩放。
      const double slot = 40 * kFushiFloatingCapsuleScale;
      for (final AdaptiveNavItem item in items) {
        final Size layer = stateLayerRect(tester, item.label).size;
        expect(layer.width, closeTo(slot, 1e-6), reason: item.label);
        expect(layer.height, closeTo(slot, 1e-6), reason: item.label);
      }
    });

    testWidgets('选中高亮是专属多边形：墨滴滑动途中不画，落定后在新项由圆变出', (WidgetTester tester) async {
      int index = 0;
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: FushiFocusRoot(
            child: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) => Scaffold(
                body: const SizedBox.expand(),
                bottomNavigationBar: adaptiveBottomBar(
                  context: context,
                  currentIndex: index,
                  onTap: (int i) => setState(() => index = i),
                  items: items,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      List<NavMorphShape> visibleShapes() => tester
          .widgetList<NavMorphShape>(find.byType(NavMorphShape))
          .where((NavMorphShape w) => w.visible)
          .toList();
      Rect visibleShapeRect() => tester.getRect(
        find.byWidgetPredicate((Widget w) => w is NavMorphShape && w.visible),
      );

      expect(visibleShapes(), hasLength(1));
      expect(
        visibleShapeRect().contains(
          tester.getCenter(find.byIcon(Icons.home).hitTestable()),
        ),
        isTrue,
      );

      await tester.tap(find.text('书架'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      // 墨滴在路上：两格都不画自己的多边形。
      expect(visibleShapes(), isEmpty);

      await tester.pumpAndSettle();
      final List<NavMorphShape> settled = visibleShapes();
      expect(settled, hasLength(1));
      expect(settled.single.color, ThemeData().colorScheme.tertiary);
      expect(
        settled.single.shape,
        isNot(MaterialShapes.circle),
        reason: '落定后是专属形状而不是圆',
      );
      expect(
        visibleShapeRect().contains(
          tester.getCenter(find.byIcon(Icons.menu_book_outlined).hitTestable()),
        ),
        isTrue,
        reason: '多边形落在新选中项的图标背后',
      );
    });
  });
}
