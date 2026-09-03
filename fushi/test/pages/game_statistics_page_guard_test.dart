import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('游戏首页不再各挂统计入口（已收敛到首页 dashboard）', () {
    // 用户定案 2026-09-01：各媒体页头的「xx统计」全部撤掉，统一从首页进
    // 统计中心；唯一入口由 home_video_statistics_entry_static_test 钉住。
    for (final String path in <String>[
      'lib/src/pages/implementations/galgame_home_page.dart',
      'lib/src/pages/implementations/home_game_page.dart',
    ]) {
      final String source = File(path).readAsStringSync();
      expect(source, isNot(contains('statistics_center_page.dart')),
          reason: path);
      expect(source, isNot(contains('StatisticsCenterPage(')), reason: path);
    }
  });

  test('游戏统计页清空入口只调用游戏统计 DAO', () {
    final String source = File(
      'lib/src/pages/implementations/game_statistics_page.dart',
    ).readAsStringSync();

    expect(source, contains('tooltip: t.stat_clear_all'));
    expect(source, contains('t.stat_clear_all_game_message'));
    expect(source, contains('clearAllGalgameStatistics()'));
    expect(source, isNot(contains('clearAllActivityEvents()')));
    expect(source, isNot(contains('clearAllReadingStatistics()')));
    expect(source, isNot(contains('clearAllVideoStatistics()')));
  });
}
