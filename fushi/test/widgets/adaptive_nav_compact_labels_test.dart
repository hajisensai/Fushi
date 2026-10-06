import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';

// 2026-10 体验优化：手机竖屏底栏最多 8 个入口，每格约 45dp。旧实现每格照样
// 画 64dp 药丸 + 标签，药丸被硬压、标签全是省略号。现在格宽 < 64 时只给选中项
// 显示标签，其余仅图标 + tooltip（MD3「仅选中项显示标签」），药丸按格宽收窄。
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

  bool labelVisible(WidgetTester tester, String label) {
    final Visibility v = tester.widget<Visibility>(
      find.ancestor(of: find.text(label), matching: find.byType(Visibility)),
    );
    return v.visible;
  }

  group('AdaptiveNavTileMetrics', () {
    test('格宽 >= 64 保持完整形态', () {
      final AdaptiveNavTileMetrics m = AdaptiveNavTileMetrics.forCellWidth(80);
      expect(m.selectedLabelOnly, isFalse);
      expect(m.pillWidth, AdaptiveNavTileMetrics.fullPillWidth);
    });

    test('侧栏（宽度未知）保持完整形态', () {
      final AdaptiveNavTileMetrics m = AdaptiveNavTileMetrics.forCellWidth(
        null,
      );
      expect(m.selectedLabelOnly, isFalse);
      expect(m.pillWidth, AdaptiveNavTileMetrics.fullPillWidth);
    });

    test('格宽 45 → 仅选中项标签，药丸随格宽收窄', () {
      final AdaptiveNavTileMetrics m = AdaptiveNavTileMetrics.forCellWidth(45);
      expect(m.selectedLabelOnly, isTrue);
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

  testWidgets('360dp 宽 8 个入口：只有选中项显示标签，其余有 tooltip', (
    WidgetTester tester,
  ) async {
    await pumpBar(tester, width: 360, count: 8, currentIndex: 2);
    expect(tester.takeException(), isNull);

    expect(labelVisible(tester, 'Tab2'), isTrue);
    for (final int i in <int>[0, 1, 3, 7]) {
      expect(labelVisible(tester, 'Tab$i'), isFalse, reason: 'Tab$i');
      expect(find.byTooltip('Tab$i'), findsOneWidget);
    }
    // 选中项不额外包 tooltip（标签已可见）。
    expect(find.byTooltip('Tab2'), findsNothing);
  });

  testWidgets('宽屏 3 个入口：全部显示标签、无 tooltip', (WidgetTester tester) async {
    await pumpBar(tester, width: 411, count: 3);
    expect(tester.takeException(), isNull);
    for (int i = 0; i < 3; i++) {
      expect(labelVisible(tester, 'Tab$i'), isTrue);
      expect(find.byTooltip('Tab$i'), findsNothing);
    }
  });
}
