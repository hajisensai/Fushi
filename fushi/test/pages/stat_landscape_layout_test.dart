import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/pages/implementations/stat_shared.dart';

/// 统计中心横屏双栏布局（[buildStatAdaptiveScrollView]）。
///
/// 横屏下竖排布局只是被拉宽，最近会话与按媒体列表全挤在折线以下；横屏改成左
/// 「概览」右「明细」两栏各自滚动，竖屏必须一处不变（区块顺序原样）。
void main() {
  group('useStatLandscapeLayout', () {
    test('wide landscape content areas split into two panes', () {
      // 手机横放（扣掉页头 / TabBar 后的内容区）。
      expect(useStatLandscapeLayout(const Size(780, 250)), isTrue);
      // 平板横放 / 桌面宽窗口。
      expect(useStatLandscapeLayout(const Size(1280, 640)), isTrue);
      expect(useStatLandscapeLayout(const Size(720, 400)), isTrue);
    });

    test('portrait and narrow content areas stay single column', () {
      // 手机竖屏、平板竖屏。
      expect(useStatLandscapeLayout(const Size(412, 700)), isFalse);
      expect(useStatLandscapeLayout(const Size(800, 1100)), isFalse);
      // 横着但太窄：劈两半后每栏放不下两列时段卡。
      expect(useStatLandscapeLayout(const Size(700, 300)), isFalse);
      // 正方形不算横。
      expect(useStatLandscapeLayout(const Size(900, 900)), isFalse);
    });

    test('unbounded sizes stay single column', () {
      expect(
        useStatLandscapeLayout(const Size(1000, double.infinity)),
        isFalse,
      );
      expect(
        useStatLandscapeLayout(const Size(double.infinity, 500)),
        isFalse,
      );
    });

    test('every landscape pane still fits two period-card columns', () {
      // 双栏阈值的依据：每栏扣掉左右 20dp 卡片内边距后，时段卡仍是 2×2。
      for (double w = kStatLandscapeMinWidth; w <= 1600; w += 1) {
        final double pane = (w - 1) / 2 - 2 * 20;
        final StatPeriodSummaryLayout layout = resolveStatPeriodSummaryLayout(
          maxWidth: pane,
          wideGap: 12,
          compactGap: 8,
        );
        expect(layout.columnWidth, isNotNull, reason: 'width=$w');
      }
    });
  });

  group('buildStatAdaptiveScrollView', () {
    final List<double> seenWidths = <double>[];

    Widget harness() {
      seenWidths.clear();
      return MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => buildStatAdaptiveScrollView(
              context,
              sections: (double columnWidth) {
                seenWidths.add(columnWidth);
                Widget box(String label) => SliverToBoxAdapter(
                      child: SizedBox(height: 40, child: Text(label)),
                    );
                return <StatPaneSliver>[
                  StatPaneSliver(StatPane.overview, box('cards')),
                  StatPaneSliver(StatPane.detail, box('sessions')),
                  StatPaneSliver(StatPane.overview, box('analysis')),
                  StatPaneSliver(StatPane.detail, box('by-media')),
                ];
              },
            ),
          ),
        ),
      );
    }

    Finder inPane(String key, String label) => find.descendant(
          of: find.byKey(ValueKey<String>(key)),
          matching: find.text(label),
        );

    testWidgets('portrait keeps one scroll view in the given order',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(412, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness());

      expect(find.byType(CustomScrollView), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('stat-landscape-overview')),
          findsNothing);
      final List<double> ys = <String>['cards', 'sessions', 'analysis']
          .map((String l) => tester.getTopLeft(find.text(l)).dy)
          .toList();
      expect(ys[0] < ys[1] && ys[1] < ys[2], isTrue, reason: '$ys');
      expect(seenWidths.last, 412);
    });

    testWidgets('landscape splits sections into side-by-side panes',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness());

      expect(find.byType(CustomScrollView), findsNWidgets(2));
      expect(inPane('stat-landscape-overview', 'cards'), findsOneWidget);
      expect(inPane('stat-landscape-overview', 'analysis'), findsOneWidget);
      expect(inPane('stat-landscape-detail', 'sessions'), findsOneWidget);
      expect(inPane('stat-landscape-detail', 'by-media'), findsOneWidget);
      expect(inPane('stat-landscape-overview', 'sessions'), findsNothing);

      // 栏内保持原相对顺序；两栏顶端对齐、左右并排。
      expect(
        tester.getTopLeft(find.text('cards')).dy,
        lessThan(tester.getTopLeft(find.text('analysis')).dy),
      );
      expect(
        tester.getTopLeft(find.text('cards')).dy,
        tester.getTopLeft(find.text('sessions')).dy,
      );
      expect(
        tester.getTopLeft(find.text('sessions')).dx,
        greaterThanOrEqualTo(600),
      );
      // 区块拿到的是本栏宽度，不是整宽（阅读页「分析」区据此决定并排与否）。
      expect(seenWidths.last, (1200 - 1) / 2);

      // 只有左栏挂 PrimaryScrollController，右栏独立滚动。
      final CustomScrollView detail = tester.widget(
        find.byKey(const ValueKey<String>('stat-landscape-detail')),
      );
      expect(detail.primary, isFalse);
    });
  });
}
