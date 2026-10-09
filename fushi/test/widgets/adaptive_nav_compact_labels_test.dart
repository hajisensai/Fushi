import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';

// 2026-10 体验优化：手机竖屏底栏最多 8 个入口，每格约 45dp。旧实现每格照样
// 画 64dp 药丸 + 标签，药丸被硬压。现在格宽 < 64 时药丸按格宽收窄、标签缩小
// 一号并按格宽省略、配 tooltip 补全名。
// 2026-10-05 用户反馈「底部栏重新显示所有文字不要隐藏」：窄格曾只给选中项显示
// 标签，现在所有入口的标签恒显示。
void main() {
  List<AdaptiveNavItem> itemsOf(int n) => <AdaptiveNavItem>[
    for (int i = 0; i < n; i++)
      AdaptiveNavItem(icon: Icons.circle_outlined, label: 'Tab$i'),
  ];

  Future<void> pumpBar(
    WidgetTester tester, {
    required double width,
    required int count,
    int currentIndex = 0,
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
                onTap: (_) {},
                items: itemsOf(count),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // 展开栏与收起的小胶囊常驻同一 Stack；隐藏分支由 IgnorePointer 禁止命中，
  // 仍在树里的当前项标题 / Tooltip 不属于屏幕上的导航目的地。
  Finder activeLabel(String label) => find.text(label).hitTestable();

  /// 标签真的画出来了：Text 可命中、没有被 Visibility / Opacity 0 藏起来，且
  /// 占了正的宽高。
  bool labelVisible(WidgetTester tester, String label) {
    final Finder text = activeLabel(label);
    if (text.evaluate().length != 1) return false;
    final Iterable<Visibility> hiders = tester.widgetList<Visibility>(
      find.ancestor(of: text, matching: find.byType(Visibility)),
    );
    if (hiders.any((Visibility v) => !v.visible)) return false;
    final Iterable<Opacity> faders = tester.widgetList<Opacity>(
      find.ancestor(of: text, matching: find.byType(Opacity)),
    );
    if (faders.any((Opacity o) => o.opacity == 0)) return false;
    final Size size = tester.getSize(text);
    return size.width > 0 && size.height > 0;
  }

  double labelFontSize(WidgetTester tester, String label) {
    final RenderParagraph p = tester.renderObject<RenderParagraph>(
      activeLabel(label),
    );
    return p.text.style!.fontSize!;
  }

  group('AdaptiveNavTileMetrics', () {
    test('格宽 >= 64 保持完整形态', () {
      final AdaptiveNavTileMetrics m = AdaptiveNavTileMetrics.forCellWidth(80);
      expect(m.compact, isFalse);
      expect(m.pillWidth, AdaptiveNavTileMetrics.fullPillWidth);
    });

    test('侧栏（宽度未知）保持完整形态', () {
      final AdaptiveNavTileMetrics m = AdaptiveNavTileMetrics.forCellWidth(
        null,
      );
      expect(m.compact, isFalse);
      expect(m.pillWidth, AdaptiveNavTileMetrics.fullPillWidth);
    });

    test('格宽 45 → 紧凑形态，药丸随格宽收窄', () {
      final AdaptiveNavTileMetrics m = AdaptiveNavTileMetrics.forCellWidth(45);
      expect(m.compact, isTrue);
      expect(m.pillWidth, lessThan(45));
      expect(
        m.pillWidth,
        greaterThanOrEqualTo(AdaptiveNavTileMetrics.pillHeight),
      );
    });

    test('极窄格药丸不低于图标药丸高度', () {
      final AdaptiveNavTileMetrics m = AdaptiveNavTileMetrics.forCellWidth(20);
      expect(m.pillWidth, AdaptiveNavTileMetrics.pillHeight);
    });
  });

  /// 标签完整画出（没有被省略号截断）。
  bool labelUntruncated(WidgetTester tester, String label) {
    final RenderParagraph p = tester.renderObject<RenderParagraph>(
      activeLabel(label),
    );
    return !p.didExceedMaxLines;
  }

  // 2026-10-06 悬浮底栏：放不下时不再把标签压成「浏览…」，而是按模块顺序
  // 从前往后放，剩下的收进最右的「更多」。出现在栏上的入口标签都完整显示。
  testWidgets('360dp 宽 8 个入口：栏上入口标签完整显示，其余收进「更多」', (WidgetTester tester) async {
    int tapped = -1;
    tester.view.physicalSize = const Size(360, 800);
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
                currentIndex: 0,
                onTap: (int i) => tapped = i,
                items: itemsOf(8),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final List<int> shown = <int>[
      for (int i = 0; i < 8; i++)
        if (activeLabel('Tab$i').evaluate().isNotEmpty) i,
    ];
    expect(shown, isNotEmpty);
    expect(find.text('More'), findsOneWidget, reason: '放不下时出现「更多」');
    // 按模块顺序从前往后放：栏上的是前缀。
    expect(shown, <int>[for (int i = 0; i < shown.length; i++) i]);
    for (final int i in shown) {
      expect(labelVisible(tester, 'Tab$i'), isTrue, reason: 'Tab$i');
      expect(labelUntruncated(tester, 'Tab$i'), isTrue, reason: 'Tab$i');
    }
    expect(labelUntruncated(tester, 'More'), isTrue);

    // 「更多」菜单列出其余入口，选中即切过去。
    await tester.tap(find.text('More'));
    await tester.pump();
    // BUG-3005：逐帧经过进场中段，不能只看动画落定后的菜单。原生菜单
    // 会把 route 曲线的值送入 Interval，欠阻尼回弹越过 1 就会断言。
    for (int frame = 0; frame < 24; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull, reason: '菜单进场第 $frame 帧');
    }
    await tester.pumpAndSettle();
    for (int i = shown.length; i < 8; i++) {
      expect(find.text('Tab$i'), findsOneWidget, reason: '菜单里有 Tab$i');
    }
    await tester.tap(find.text('Tab7'));
    await tester.pumpAndSettle();
    expect(tapped, 7);
  });

  testWidgets('长标签放不下时整条收进「更多」而不是省略或溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 800);
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
                currentIndex: 0,
                onTap: (_) {},
                items: <AdaptiveNavItem>[
                  for (int i = 0; i < 8; i++)
                    AdaptiveNavItem(
                      icon: Icons.circle_outlined,
                      label: 'Browser extension $i',
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    for (int i = 0; i < 8; i++) {
      final Finder label = activeLabel('Browser extension $i');
      if (label.evaluate().isEmpty) continue;
      expect(labelUntruncated(tester, 'Browser extension $i'), isTrue);
    }
    expect(find.text('More'), findsOneWidget);
  });

  testWidgets('宽屏 3 个入口：全部显示标签、无 tooltip', (WidgetTester tester) async {
    await pumpBar(tester, width: 411, count: 3);
    expect(tester.takeException(), isNull);
    for (int i = 0; i < 3; i++) {
      expect(labelVisible(tester, 'Tab$i'), isTrue);
      expect(labelFontSize(tester, 'Tab$i'), 12);
      expect(find.byTooltip('Tab$i').hitTestable(), findsNothing);
    }
  });

  // 2026-10-06 用户「底部栏的文字砍掉」：出厂纯图标底栏（偏好
  // nav_bar_labels_visible 默认关）。名称不画成文字，但仍是 tooltip 与无障碍
  // 名称；每格至少 48dp 触控目标，选中胶囊照常。
  testWidgets('纯图标底栏：不画标签文字，tooltip + 语义保留原文案，格宽 >= 48', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    // material_ui 的 Tooltip 与 flutter_test 的 find.byTooltip 认的 SDK 类型不同，
    // 按类型 + message 直接找。
    Finder tooltipNamed(String message) => find.byWidgetPredicate(
      (Widget w) => w is Tooltip && w.message == message,
    );
    int tapped = -1;
    tester.view.physicalSize = const Size(411, 800);
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
                currentIndex: 1,
                onTap: (int i) => tapped = i,
                showLabels: false,
                items: itemsOf(6),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    for (int i = 0; i < 6; i++) {
      expect(activeLabel('Tab$i'), findsNothing, reason: 'Tab$i 不画文字');
      final Finder tip = tooltipNamed('Tab$i');
      expect(tip, findsWidgets, reason: 'Tab$i 有 tooltip');
      expect(
        find.bySemanticsLabel('Tab$i'),
        findsWidgets,
        reason: 'Tab$i 语义名称',
      );
      final Finder icon = find.descendant(
        of: tip,
        matching: find.byIcon(Icons.circle_outlined),
      );
      expect(icon, findsWidgets);
    }
    // 每个入口的可点区（包住整格的 InkWell）至少 48×48。
    for (int i = 0; i < 6; i++) {
      final Finder ink = find
          .ancestor(
            of: tooltipNamed('Tab$i').first,
            matching: find.byWidgetPredicate((Widget w) => w is InkWell),
          )
          .first;
      final Size cell = tester.getSize(ink);
      expect(cell.width, greaterThanOrEqualTo(48), reason: 'Tab$i 宽');
      expect(cell.height, greaterThanOrEqualTo(48), reason: 'Tab$i 高');
    }
    await tester.tap(tooltipNamed('Tab3').first);
    await tester.pump();
    expect(tapped, 3);
    semantics.dispose();
  });
}
