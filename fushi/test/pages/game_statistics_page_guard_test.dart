import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('两套游戏首页都接入独立游戏统计页', () {
    for (final String path in <String>[
      'lib/src/pages/implementations/galgame_home_page.dart',
      'lib/src/pages/implementations/home_game_page.dart',
    ]) {
      final String source = File(path).readAsStringSync();
      expect(source, contains('game_statistics_page.dart'), reason: path);
      expect(source, contains('GameStatisticsPage()'), reason: path);
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
