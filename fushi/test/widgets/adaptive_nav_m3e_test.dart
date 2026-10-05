import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

// 2026-10-05 用户：「导航栏和侧边栏也统一成 m3e」。
//
// MD3 设计系统的应用级导航按 M3 Expressive 规格：
// - 宽屏 navigation rail 有收起（96）/ 展开（220，取代旧侧边抽屉）两态，顶部
//   菜单钮切换，宽度走 spatial 弹簧；两态都恒显示文字标签；
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

  bool labelPainted(WidgetTester tester, String label) {
    final Finder text = find.text(label);
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
      expect(find.byIcon(FushiIcons.chevronLeft), findsOneWidget);
      expect(find.byTooltip('Collapse navigation'), findsOneWidget);

      await tester.tap(find.byIcon(FushiIcons.chevronLeft));
      await tester.pumpAndSettle();
      expect(expanded.value, isFalse);
      expect(railWidth(tester), kMaterialNavRailCollapsedWidth);
      expect(tester.takeException(), isNull);
    });

    testWidgets('两态都恒显示全部文字标签', (WidgetTester tester) async {
      final ValueNotifier<bool> expanded = await pumpToggleRail(tester);
      for (final AdaptiveNavItem item in items) {
        expect(labelPainted(tester, item.label), isTrue, reason: item.label);
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
              of: find.byIcon(FushiIcons.chevronLeft),
              matching: find.byWidgetPredicate((Widget w) => w is InkWell),
            )
            .first,
      );
      final Size menu = tester.getSize(
        find
            .ancestor(
              of: find.byIcon(FushiIcons.chevronLeft),
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
            of: find.text(label),
            matching: find.byWidgetPredicate((Widget w) => w is InkWell),
          )
          .first;
      final InkWell inkWell = tester.widget<InkWell>(ink);
      final RenderBox ref = tester.renderObject<RenderBox>(ink);
      final RectCallback? callback = inkWell.getRectCallback(ref);
      final Rect local = callback == null ? Offset.zero & ref.size : callback();
      return local.shift(ref.localToGlobal(Offset.zero));
    }

    testWidgets('手机宽：竖排目的地、64 高、全部标签可见', (WidgetTester tester) async {
      await pumpBar(tester, width: 420);
      expect(
        tester.getSize(find.byKey(fushiMaterialNavKey)).height,
        kAdaptiveNavBarFloatingTopGap +
            kAdaptiveNavBarContentHeight +
            kAdaptiveNavFloatingMargin,
      );
      for (final AdaptiveNavItem item in items) {
        expect(labelPainted(tester, item.label), isTrue, reason: item.label);
        final Rect icon = tester.getRect(find.byIcon(item.icon));
        final Rect label = tester.getRect(find.text(item.label));
        expect(icon.bottom, lessThanOrEqualTo(label.top), reason: '图标在上');
      }
      // 悬停 / 按压状态层与活动指示器同框（56×32 全圆角药丸）。
      for (final AdaptiveNavItem item in items) {
        expect(
          stateLayerRect(tester, item.label).size,
          const Size(
            AdaptiveNavTileMetrics.fullPillWidth,
            AdaptiveNavTileMetrics.pillHeight,
          ),
          reason: item.label,
        );
      }
    });

    testWidgets('活动指示器按弹簧展开：中途介于两端，落点精确 56 且实底', (WidgetTester tester) async {
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

      Container pillOf(IconData icon) => tester.widget<Container>(
        find
            .ancestor(
              of: find.byIcon(icon),
              matching: find.byWidgetPredicate(
                (Widget w) => w is Container && w.decoration is BoxDecoration,
              ),
            )
            .first,
      );
      double pillWidthOf(IconData icon) => tester
          .getSize(
            find
                .ancestor(
                  of: find.byIcon(icon),
                  matching: find.byWidgetPredicate(
                    (Widget w) =>
                        w is Container && w.decoration is BoxDecoration,
                  ),
                )
                .first,
          )
          .width;

      await tester.tap(find.text('书架'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final double mid = pillWidthOf(Icons.menu_book_outlined);
      expect(mid, greaterThan(AdaptiveNavTileMetrics.pillHeight));
      expect(mid, lessThan(AdaptiveNavTileMetrics.fullPillWidth));

      // 回弹最多超出 8（画在格内边距里），不会无限扩张。
      double maxSeen = 0;
      for (int i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final double w = pillWidthOf(Icons.menu_book_outlined);
        if (w > maxSeen) maxSeen = w;
      }
      expect(
        maxSeen,
        lessThanOrEqualTo(AdaptiveNavTileMetrics.fullPillWidth + 8),
      );

      await tester.pumpAndSettle();
      expect(
        pillWidthOf(Icons.menu_book_outlined),
        AdaptiveNavTileMetrics.fullPillWidth,
      );
      final BoxDecoration settled =
          pillOf(Icons.menu_book_outlined).decoration! as BoxDecoration;
      expect(
        settled.color,
        ThemeData().colorScheme.tertiary,
        reason: '静止后与目标色逐值相同',
      );
      // 取消选中的那一格收拢成透明。
      final BoxDecoration old =
          pillOf(Icons.home_outlined).decoration! as BoxDecoration;
      expect(old.color, Colors.transparent);
    });
  });
}
