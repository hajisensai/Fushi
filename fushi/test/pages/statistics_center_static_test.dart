import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 阶段 2（统计中心大一统）结构守卫：
///  * 三域 tab 必须以 embedded 模式复用现有统计页（不嵌套 FushiPageScaffold，
///    避免双 Scaffold/双顶栏 + PageScrollRegistry 互踩）；
///  * 总览 tab 的目标分子必须走 studyGoalCharsForDay（BUG-1993 口径），时段明细
///    必须走统一 sheet（showStatPeriodDetailSheet）；
///  * 书架入口必须落阅读 tab（视频/游戏入口由
///    home_video_statistics_entry_static_test / game_statistics_page_guard_test
///    分别钉住）。
void main() {
  final String center = File(
    'lib/src/pages/implementations/statistics_center_page.dart',
  ).readAsStringSync();

  test('三域 tab 以 embedded 模式复用现有统计页', () {
    expect(center, contains('ReadingStatisticsPage(embedded: true)'));
    expect(center, contains('VideoStatisticsPage(embedded: true)'));
    expect(center, contains('GameStatisticsPage(embedded: true)'));
    expect(
      center,
      isNot(contains('FushiPageScaffold(embedded')),
      reason: '嵌入模式由各页自身分支处理，中心页不重复造壳',
    );
  });

  test('总览 tab：目标口径 + 统一时段明细 sheet', () {
    expect(center, contains('studyGoalCharsForDay('));
    expect(center, contains('showStatPeriodDetailSheet('));
  });

  test('三个统计页都支持 embedded 分支（buildEmbeddedStatTab）', () {
    for (final String path in <String>[
      'lib/src/pages/implementations/reading_statistics_page.dart',
      'lib/src/pages/implementations/video_statistics_page.dart',
      'lib/src/pages/implementations/game_statistics_page.dart',
    ]) {
      final String source = File(path).readAsStringSync();
      expect(source, contains('buildEmbeddedStatTab('), reason: path);
    }
  });

  test('统计入口唯一落点在首页 dashboard（书架不再直连）', () {
    // 用户定案 2026-09-01：入口收敛。首页入口的正向断言在
    // home_video_statistics_entry_static_test，这里只钉书架侧不回潮。
    final String shelf = File(
      'lib/src/pages/implementations/reader_fushi_history_page.dart',
    ).readAsStringSync();
    expect(shelf, isNot(contains('StatisticsCenterPage(')));
  });
}
