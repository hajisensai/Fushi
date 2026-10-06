import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:material_ui/material_ui.dart';

// 2026-10-07 用户：「反转底栏方向要查词模块在左侧 移动端这个」。
//
// 手机底栏把「查词」拆成悬浮胶囊旁的独立按钮（MD3 = 大号 FAB，Apple = 圆形玻璃
// 钮），此前恒在右侧：开了「反转底栏方向」，胶囊里的目的地翻了，查词钮却还钉在
// 右边。现在反转时整条底栏镜像——查词钮在最左，胶囊目的地顺序与关闭时相反；
// 关闭时布局不变。键盘 / 手柄从最左往右走的顺序与视觉顺序一致。
void main() {
  // 首页 tab 顺序的缩影：首页 / 书架 / 视频 / 查词 / 设置。
  const List<AdaptiveNavItem> items = <AdaptiveNavItem>[
    AdaptiveNavItem(icon: Icons.home_outlined, label: '首页'),
    AdaptiveNavItem(icon: Icons.menu_book_outlined, label: '书架'),
    AdaptiveNavItem(icon: Icons.movie_outlined, label: '视频'),
    AdaptiveNavItem(icon: Icons.search, label: '查词'),
    AdaptiveNavItem(icon: Icons.tune_outlined, label: '设置'),
  ];
  const int searchIndex = 3;

  /// 按首页 `_buildMobileLayout` 的组装方式泵出手机宽度的底栏：反转时目的地
  /// 列表倒序、查词的视觉序号随之镜像，并把 `searchLeading` 设成反转值。
  Future<void> pumpBar(
    WidgetTester tester, {
    required bool reversed,
    bool glassDesign = false,
    bool minimized = false,
  }) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final List<AdaptiveNavItem> display = reversed
        ? items.reversed.toList()
        : items;
    final int search = reversed ? items.length - 1 - searchIndex : searchIndex;
    // 当前页 = 首页（视觉上反转时在最右）。
    final int current = reversed ? items.length - 1 : 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFushiThemeData(
          scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          textTheme: Typography.material2021().black,
          glass: glassDesign
              ? FushiGlassMaterial.liquid
              : FushiGlassMaterial.off,
          glassDesign: glassDesign,
        ),
        themeAnimationDuration: Duration.zero,
        home: FushiGlassScope(
          child: FushiFocusRoot(
            child: Scaffold(
              body: const SizedBox.expand(),
              bottomNavigationBar: Builder(
                builder: (BuildContext context) => FocusTraversalGroup(
                  child: adaptiveBottomBar(
                    context: context,
                    currentIndex: current,
                    onTap: (_) {},
                    items: display,
                    glassSearchIndex: search,
                    showLabels: false,
                    searchLeading: reversed,
                    glassMinimized: minimized,
                    onGlassExpand: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder target(String id) => find.byWidgetPredicate(
    (Widget w) => w is FushiFocusTarget && w.id == FushiFocusId(id),
  );

  double centerX(WidgetTester tester, Finder finder) =>
      tester.getCenter(finder).dx;

  /// 某个目的地（按原始 [items] 序号）的焦点目标：MD3 的查词是 FAB
  /// （`nav-bar-fab`），其余（含 Apple 的搜索圆钮）是 `nav-bar-<视觉序号>`。
  Finder itemTarget(int itemIndex, {required bool reversed, bool fab = true}) {
    if (fab && itemIndex == searchIndex) return target('nav-bar-fab');
    final int visual = reversed ? items.length - 1 - itemIndex : itemIndex;
    return target('nav-bar-$visual');
  }

  /// 按视觉从左到右排的目的地标签。
  List<String> visualOrder(
    WidgetTester tester, {
    required bool reversed,
    bool fab = true,
  }) {
    final List<MapEntry<String, double>> xs =
        <MapEntry<String, double>>[
          for (int i = 0; i < items.length; i++)
            MapEntry<String, double>(
              items[i].label,
              centerX(tester, itemTarget(i, reversed: reversed, fab: fab)),
            ),
        ]..sort(
          (MapEntry<String, double> a, MapEntry<String, double> b) =>
              a.value.compareTo(b.value),
        );
    return <String>[for (final MapEntry<String, double> e in xs) e.key];
  }

  /// 从 [startId] 开始一路按「向右」，记录经过的焦点目标中心 x（走不动或回到
  /// 已走过的目标即停）。
  Future<List<double>> walkRight(WidgetTester tester, String startId) async {
    final FushiFocusController controller = FushiFocusRoot.controllerOf(
      tester.element(find.byKey(fushiMaterialNavKey)),
    );
    expect(controller.requestById(FushiFocusId(startId)), isTrue);
    await tester.pump();
    final List<String> seen = <String>[startId];
    final List<double> xs = <double>[centerX(tester, target(startId))];
    for (int step = 0; step < items.length + 2; step++) {
      if (!controller.move(FushiFocusDirection.right)) break;
      await tester.pump();
      final String id = controller.activeId!.value;
      if (seen.contains(id)) break;
      seen.add(id);
      xs.add(centerX(tester, target(id)));
    }
    return xs;
  }

  group('MD3 悬浮底栏', () {
    testWidgets('反转关：查词 FAB 在最右，目的地正序（与现状一致）', (WidgetTester tester) async {
      await pumpBar(tester, reversed: false);
      expect(visualOrder(tester, reversed: false), <String>[
        '首页',
        '书架',
        '视频',
        '设置',
        '查词',
      ]);
      final Rect fab = tester.getRect(target('nav-bar-fab'));
      final Rect bar = tester.getRect(find.byKey(fushiMaterialNavKey));
      expect(
        bar.right - fab.right,
        moreOrLessEquals(kAdaptiveNavFloatingMargin, epsilon: 1),
        reason: 'FAB 贴右侧留白',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('反转开：查词 FAB 在最左，其余目的地镜像', (WidgetTester tester) async {
      await pumpBar(tester, reversed: true);
      expect(visualOrder(tester, reversed: true), <String>[
        '查词',
        '设置',
        '视频',
        '书架',
        '首页',
      ]);
      final Rect fab = tester.getRect(target('nav-bar-fab'));
      final Rect bar = tester.getRect(find.byKey(fushiMaterialNavKey));
      expect(
        fab.left - bar.left,
        moreOrLessEquals(kAdaptiveNavFloatingMargin, epsilon: 1),
        reason: 'FAB 贴左侧留白，与关闭时镜像',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('反转开：方向键从查词 FAB 向右遍历，顺序与视觉顺序一致', (WidgetTester tester) async {
      await pumpBar(tester, reversed: true);
      final List<double> xs = await walkRight(tester, 'nav-bar-fab');
      expect(xs.length, items.length, reason: 'FAB + 4 个胶囊目的地都走到');
      for (int i = 1; i < xs.length; i++) {
        expect(xs[i], greaterThan(xs[i - 1]), reason: '第 $i 步应在上一步右边');
      }
    });

    testWidgets('反转关：方向键从首页向右遍历，最后到查词 FAB', (WidgetTester tester) async {
      await pumpBar(tester, reversed: false);
      final List<double> xs = await walkRight(tester, 'nav-bar-0');
      expect(xs.length, items.length);
      for (int i = 1; i < xs.length; i++) {
        expect(xs[i], greaterThan(xs[i - 1]));
      }
      expect(xs.last, centerX(tester, target('nav-bar-fab')));
    });

    testWidgets('反转开：Tab 键遍历顺序与视觉顺序一致', (WidgetTester tester) async {
      await pumpBar(tester, reversed: true);
      final FushiFocusController controller = FushiFocusRoot.controllerOf(
        tester.element(find.byKey(fushiMaterialNavKey)),
      );
      expect(controller.requestById(const FushiFocusId('nav-bar-fab')), isTrue);
      await tester.pump();
      final List<double> xs = <double>[centerX(tester, target('nav-bar-fab'))];
      for (int i = 1; i < items.length; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final FushiFocusId? id = controller.activeId;
        expect(id, isNotNull);
        xs.add(centerX(tester, target(id!.value)));
      }
      for (int i = 1; i < xs.length; i++) {
        expect(xs[i], greaterThan(xs[i - 1]), reason: 'Tab 第 $i 步应往右');
      }
    });
  });

  group('MD3 悬浮底栏随滚动收起', () {
    // 收起小胶囊与 FAB 分居两端：关闭反转时小胶囊在最左、FAB 在最右；开启反转
    // 时整条镜像——FAB 在最左、小胶囊缩到最右。
    testWidgets('反转关：小胶囊在左，FAB 在右', (WidgetTester tester) async {
      await pumpBar(tester, reversed: false, minimized: true);
      final Finder mini = target('nav-mini-bar');
      expect(mini, findsOneWidget);
      expect(centerX(tester, mini), lessThan(195));
      expect(centerX(tester, target('nav-bar-fab')), greaterThan(195));
      expect(tester.takeException(), isNull);
    });

    testWidgets('反转开：FAB 在左，小胶囊缩到右', (WidgetTester tester) async {
      await pumpBar(tester, reversed: true, minimized: true);
      final Finder mini = target('nav-mini-bar');
      expect(mini, findsOneWidget);
      expect(centerX(tester, target('nav-bar-fab')), lessThan(195));
      expect(centerX(tester, mini), greaterThan(195));
      expect(tester.takeException(), isNull);
    });
  });

  group('MD3 悬浮底栏放不下时的「更多」', () {
    // 手机常见的 7 个 tab（首页 / 书架 / 漫画 / 视频 / 浏览 / 查词 / 设置），
    // 纯图标在 320 宽（最窄手机）放不下：关闭反转时首页一侧全显示、末尾收进
    // 最右的「更多」；开启反转时镜像——首页一侧仍全显示（在最右），「更多」在最左紧挨查词 FAB。
    const List<AdaptiveNavItem> seven = <AdaptiveNavItem>[
      AdaptiveNavItem(icon: Icons.home_outlined, label: '首页'),
      AdaptiveNavItem(icon: Icons.menu_book_outlined, label: '书架'),
      AdaptiveNavItem(icon: Icons.collections_outlined, label: '漫画'),
      AdaptiveNavItem(icon: Icons.movie_outlined, label: '视频'),
      AdaptiveNavItem(icon: Icons.explore_outlined, label: '浏览'),
      AdaptiveNavItem(icon: Icons.search, label: '查词'),
      AdaptiveNavItem(icon: Icons.tune_outlined, label: '设置'),
    ];
    const int sevenSearch = 5;

    Future<void> pumpSeven(
      WidgetTester tester, {
      required bool reversed,
    }) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final List<AdaptiveNavItem> display = reversed
          ? seven.reversed.toList()
          : seven;
      await tester.pumpWidget(
        MaterialApp(
          home: FushiFocusRoot(
            child: Scaffold(
              body: const SizedBox.expand(),
              bottomNavigationBar: Builder(
                builder: (BuildContext context) => adaptiveBottomBar(
                  context: context,
                  currentIndex: reversed ? seven.length - 1 : 0,
                  onTap: (_) {},
                  items: display,
                  glassSearchIndex: reversed
                      ? seven.length - 1 - sevenSearch
                      : sevenSearch,
                  showLabels: false,
                  searchLeading: reversed,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('反转关：「更多」在胶囊最右，首页在最左', (WidgetTester tester) async {
      await pumpSeven(tester, reversed: false);
      final Finder more = target('nav-bar-more');
      expect(more, findsOneWidget, reason: '7 个 tab 在手机宽度下需要「更多」');
      final double moreX = centerX(tester, more);
      final double homeX = centerX(tester, target('nav-bar-0'));
      final double fabX = centerX(tester, target('nav-bar-fab'));
      expect(homeX, lessThan(moreX));
      expect(moreX, lessThan(fabX));
    });

    testWidgets('反转开：「更多」在最左紧挨查词 FAB，首页在最右', (WidgetTester tester) async {
      await pumpSeven(tester, reversed: true);
      final Finder more = target('nav-bar-more');
      expect(more, findsOneWidget);
      final double moreX = centerX(tester, more);
      final double fabX = centerX(tester, target('nav-bar-fab'));
      final Finder home = target('nav-bar-${seven.length - 1}');
      expect(home, findsOneWidget, reason: '首页一侧应完整显示，不被收进「更多」');
      final double homeX = centerX(tester, home);
      expect(fabX, lessThan(moreX));
      expect(moreX, lessThan(homeX));
      // 「更多」左边除了 FAB 不再有别的目的地。
      for (int i = 0; i < seven.length; i++) {
        final Finder cell = target('nav-bar-$i');
        if (cell.evaluate().isEmpty) continue;
        expect(centerX(tester, cell), greaterThan(moreX), reason: 'nav-bar-$i');
      }
    });

    /// 胶囊里实际显示的目的地标签（按原始顺序，不含「更多」与 FAB）。
    Set<String> shownLabels(WidgetTester tester, {required bool reversed}) =>
        <String>{
          for (int v = 0; v < seven.length; v++)
            if (target('nav-bar-$v').evaluate().isNotEmpty)
              (reversed ? seven.reversed.toList() : seven)[v].label,
        };

    Future<List<String>> moreMenuLabels(WidgetTester tester) async {
      await tester.tap(target('nav-bar-more'));
      await tester.pumpAndSettle();
      final List<String> labels = <String>[
        for (final Element e
            in find
                .byWidgetPredicate((Widget w) => w is PopupMenuItem<int>)
                .evaluate())
          for (final Text text
              in find
                  .descendant(
                    of: find.byWidget(e.widget),
                    matching: find.byType(Text),
                  )
                  .evaluate()
                  .map((Element t) => t.widget as Text))
            text.data!,
      ];
      // 关掉菜单，免得下一次 pump 复用同一个 Navigator 时菜单还挂着。
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      return labels;
    }

    testWidgets('反转开关两种状态显示同一批目的地，「更多」菜单都按用户顺序列出', (WidgetTester tester) async {
      await pumpSeven(tester, reversed: false);
      final Set<String> shownOff = shownLabels(tester, reversed: false);
      final List<String> menuOff = await moreMenuLabels(tester);
      await pumpSeven(tester, reversed: true);
      final Set<String> shownOn = shownLabels(tester, reversed: true);
      final List<String> menuOn = await moreMenuLabels(tester);
      expect(menuOff, isNotEmpty);
      expect(shownOn, shownOff);
      expect(menuOn, menuOff);
      // 菜单是用户顺序（[seven] 的子序列）。
      final List<String> userOrder = <String>[
        for (final AdaptiveNavItem item in seven)
          if (menuOff.contains(item.label)) item.label,
      ];
      expect(menuOff, userOrder);
    });
  });

  group('Apple 玻璃底栏', () {
    testWidgets('反转关：搜索圆钮在最右', (WidgetTester tester) async {
      await pumpBar(tester, reversed: false, glassDesign: true);
      expect(visualOrder(tester, reversed: false, fab: false), <String>[
        '首页',
        '书架',
        '视频',
        '设置',
        '查词',
      ]);
    });

    testWidgets('反转开：搜索圆钮在最左，其余镜像', (WidgetTester tester) async {
      await pumpBar(tester, reversed: true, glassDesign: true);
      expect(visualOrder(tester, reversed: true, fab: false), <String>[
        '查词',
        '设置',
        '视频',
        '书架',
        '首页',
      ]);
    });
  });

  test('首页手机布局把「反转底栏方向」传给底栏的 searchLeading', () {
    final String source = File(
      'lib/src/pages/implementations/home_page.dart',
    ).readAsStringSync();
    final int start = source.indexOf('Widget _buildMobileLayout()');
    expect(start, isNonNegative);
    final int end = source.indexOf('AdaptiveNavFab? _shellPageFab()', start);
    expect(end, greaterThan(start));
    final String body = source.substring(start, end);
    expect(
      body,
      contains('final bool reversed = appModel.reverseNavigationBar;'),
    );
    expect(body, contains('searchLeading: reversed,'));
  });
}
