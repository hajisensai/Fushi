import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/stat_dashboard.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';

/// 统计页宽屏两栏（2026-10 统计中心重设计，[StatDashboardBody]）的阈值依据。
/// 两栏 / 单栏的真实排布由 `stat_overview_test.dart` 直测。
void main() {
  test(
    'every wide dashboard detail column still fits two period-card columns',
    () {
      // 两栏阈值的依据：明细栏（3:2 的 2 份）扣掉左右 20dp 卡片内边距后，时段卡
      // 仍是 2×2。
      for (double w = kStatDashboardWideMinWidth; w <= 1600; w += 1) {
        final double pane = w * 2 / 5 - 2 * 20;
        final StatPeriodSummaryLayout layout = resolveStatPeriodSummaryLayout(
          maxWidth: pane,
          wideGap: 12,
          compactGap: 8,
        );
        expect(layout.columnWidth, isNotNull, reason: 'width=$w');
      }
    },
  );
}
