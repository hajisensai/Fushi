import 'package:flutter/material.dart';
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

  /// 标签真的画出来了：Text 在树里、没有被 Visibility / Opacity 0 藏起来，且
  /// 占了正的宽高。
  bool labelVisible(WidgetTester tester, String label) {
    final Finder text = find.text(label);
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
      find.text(label),
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

  testWidgets('360dp 宽 8 个入口：所有入口都显示标签（小一号），并有 tooltip', (
    WidgetTester tester,
  ) async {
    await pumpBar(tester, width: 360, count: 8, currentIndex: 2);
    expect(tester.takeException(), isNull);

    for (int i = 0; i < 8; i++) {
      expect(labelVisible(tester, 'Tab$i'), isTrue, reason: 'Tab$i');
      expect(labelFontSize(tester, 'Tab$i'), 11, reason: 'Tab$i');
      expect(find.byTooltip('Tab$i'), findsOneWidget);
    }
  });

  testWidgets('窄格长标签按格宽省略而不是溢出或隐藏', (WidgetTester tester) async {
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
      final String label = 'Browser extension $i';
      expect(labelVisible(tester, label), isTrue, reason: label);
      expect(tester.getSize(find.text(label)).width, lessThanOrEqualTo(40));
    }
  });

  testWidgets('宽屏 3 个入口：全部显示标签、无 tooltip', (WidgetTester tester) async {
    await pumpBar(tester, width: 411, count: 3);
    expect(tester.takeException(), isNull);
    for (int i = 0; i < 3; i++) {
      expect(labelVisible(tester, 'Tab$i'), isTrue);
      expect(labelFontSize(tester, 'Tab$i'), 12);
      expect(find.byTooltip('Tab$i'), findsNothing);
    }
  });
}
