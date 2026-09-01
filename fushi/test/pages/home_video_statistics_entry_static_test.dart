import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：统计入口的唯一落点是首页 dashboard（用户定案 2026-09-01：各媒体页头
/// 的「xx统计」全部撤掉，统一从首页热力图卡进统计中心总览）。
///
/// 历史：本守卫最初钉「视频页头 → VideoStatisticsPage」，阶段 2 改钉「视频页头
/// → 统计中心观看 tab」，入口收敛后翻转为「视频页头**没有**统计入口 + 首页
/// dashboard **有**统计中心入口」。
void main() {
  test('home_dashboard_page 是统计中心的唯一入口', () {
    final String dashboard = File(
      'lib/src/pages/implementations/home_dashboard_page.dart',
    ).readAsStringSync();
    expect(
      dashboard.contains(
          "import 'package:fushi/src/pages/implementations/statistics_center_page.dart';"),
      isTrue,
      reason: '首页应导入 StatisticsCenterPage',
    );
    expect(dashboard.contains('_openStatisticsCenter'), isTrue,
        reason: '首页应有统计中心入口处理器');
    expect(dashboard.contains('StatisticsCenterPage()'), isTrue,
        reason: '入口应 push 统计中心（总览 tab）');
  });

  test('媒体页头不再各挂统计入口', () {
    for (final String path in <String>[
      'lib/src/pages/implementations/home_video_page.dart',
      'lib/src/pages/implementations/reader_fushi_history_page.dart',
      'lib/src/pages/implementations/home_game_page.dart',
      'lib/src/pages/implementations/galgame_home_page.dart',
    ]) {
      final String source = File(path).readAsStringSync();
      expect(source.contains('StatisticsCenterPage('), isFalse,
          reason: '$path：统计入口已收敛到首页，不应再 push 统计中心');
      expect(source.contains('_openStatistics'), isFalse,
          reason: '$path：媒体页头的统计入口处理器应随入口一起删除');
    }
  });
}
