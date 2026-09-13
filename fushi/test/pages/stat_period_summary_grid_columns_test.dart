import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/pages/implementations/stat_shared.dart';

/// 统计中心「今日 / 本周 / 本月 / 全部」在手机上只显示一列的回归测试。
///
/// 根因：[buildStatPeriodSummaryGrid] 旧实现按「可用宽度 ≥ 380」判两列，但这层
/// 外面还有 20dp 的左右内边距，360dp 手机到这里只剩 320dp、412dp 大屏手机也只有
/// 372dp——阈值结构上高于任何手机宽度，两列分支在手机上永远走不到。修复：改按
/// 实际算出的**列宽**判（[resolveStatPeriodSummaryLayout]）。
void main() {
  // 生产实参：wideGap = gap * 1.5 = 12，compactGap = gap = 8。
  const double wideGap = 12;
  const double compactGap = 8;

  StatPeriodSummaryLayout layoutAt(double maxWidth) =>
      resolveStatPeriodSummaryLayout(
        maxWidth: maxWidth,
        wideGap: wideGap,
        compactGap: compactGap,
      );

  group('resolveStatPeriodSummaryLayout', () {
    test('phone widths get two columns', () {
      // 360dp 手机 − 2×20dp 内边距 = 320dp；旧阈值 380 在这里判单列。
      expect(layoutAt(320).columnWidth, isNotNull);
      // 412dp 大屏手机 − 40 = 372dp，同样低于旧阈值 380。
      expect(layoutAt(372).columnWidth, isNotNull);
      // 375dp iPhone − 40 = 335dp。
      expect(layoutAt(335).columnWidth, isNotNull);
    });

    test('narrow columns switch the card to compact padding', () {
      expect(layoutAt(320).compact, isTrue);
      // 平板宽度列宽充裕，保持原内边距。
      final StatPeriodSummaryLayout tablet = layoutAt(728);
      expect(tablet.compact, isFalse);
      expect(tablet.columnWidth, (728 - wideGap) / 2);
    });

    test('very narrow widths fall back to a single column', () {
      // 320dp 小屏机 − 40 = 280dp：两种间距下列宽都 < 144，退单列。
      final StatPeriodSummaryLayout tiny = layoutAt(280);
      expect(tiny.columnWidth, isNull);
      expect(tiny.gap, wideGap);
      expect(tiny.compact, isFalse);
    });

    test('compact gap rescues widths that just miss with the wide gap', () {
      // (maxWidth − 12) / 2 < 144 <= (maxWidth − 8) / 2 的窄带：296..299。
      final StatPeriodSummaryLayout squeezed = layoutAt(296);
      expect(squeezed.columnWidth, isNotNull);
      expect(squeezed.gap, compactGap);
    });

    test('unbounded width falls back to a single column', () {
      expect(layoutAt(double.infinity).columnWidth, isNull);
    });

    test('two columns never overflow the available width', () {
      for (double w = 144; w <= 900; w += 1) {
        final StatPeriodSummaryLayout l = layoutAt(w);
        final double? column = l.columnWidth;
        if (column == null) continue;
        expect(column * 2 + l.gap, lessThanOrEqualTo(w + 0.001),
            reason: 'maxWidth=$w');
        expect(column, greaterThanOrEqualTo(kStatPeriodSummaryMinColumnWidth),
            reason: 'maxWidth=$w');
      }
    });
  });

  testWidgets('four period cards lay out 2x2 at phone width',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => buildStatPeriodSummaryGrid(
            context,
            const <StatPeriodSummary>[
              StatPeriodSummary(label: 'Today', primaryValue: '12 min'),
              StatPeriodSummary(label: 'Week', primaryValue: '3 hr 20 min'),
              StatPeriodSummary(label: 'Month', primaryValue: '18 hr 5 min'),
              StatPeriodSummary(label: 'All', primaryValue: '412 hr 9 min'),
            ],
          ),
        ),
      ),
    ));

    final List<double> lefts = <double>[];
    final List<double> tops = <double>[];
    for (final String label in <String>['Today', 'Week', 'Month', 'All']) {
      final Offset o = tester.getTopLeft(find.text(label));
      lefts.add(o.dx);
      tops.add(o.dy);
    }
    // 两列：1/3 同列左对齐、2/4 同列左对齐，且第二列明显靠右。
    expect(lefts[0], lefts[2]);
    expect(lefts[1], lefts[3]);
    expect(lefts[1], greaterThan(lefts[0] + 100));
    // 两行：1/2 同行、3/4 同行，第二行在下。
    expect(tops[0], tops[1]);
    expect(tops[2], tops[3]);
    expect(tops[2], greaterThan(tops[0]));
  });
}
