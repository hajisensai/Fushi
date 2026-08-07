import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/pages/implementations/game_stat_aggregates.dart';

GalgameEntry _game(
  String id, {
  required int seconds,
  required int sessions,
  required int lastPlayedMs,
}) {
  return GalgameEntry(
    id: id,
    name: id,
    exePath: '$id.exe',
    workdir: '.',
    addedAt: DateTime(2026),
    totalPlaySeconds: seconds,
    sessionCount: sessions,
    lastPlayedMs: lastPlayedMs,
  );
}

void main() {
  final DateTime now = DateTime(2026, 7, 29, 12);

  test('游戏窗口只聚合 galgame_sessions 的按日事实', () {
    final GameStatsAggregate aggregate = computeGameStats(
      games: <GalgameEntry>[
        _game('a', seconds: 7200, sessions: 2, lastPlayedMs: 20),
      ],
      dailyTotals: <String, (int, int)>{
        '2026-07-29': (1800, 1),
        '2026-07-25': (3600, 2),
        '2026-06-20': (7200, 3),
      },
      now: now,
    );

    expect(aggregate.todayMs, 1800 * 1000);
    expect(aggregate.todaySessions, 1);
    expect(aggregate.weekMs, (1800 + 3600) * 1000);
    expect(aggregate.weekSessions, 3);
    expect(aggregate.monthMs, (1800 + 3600) * 1000);
    expect(aggregate.allMs, (1800 + 3600 + 7200) * 1000);
    expect(aggregate.allSessions, 6);
  });

  test('近 30 天补零且按游戏时长降序，未游玩游戏不进入列表', () {
    final GameStatsAggregate aggregate = computeGameStats(
      games: <GalgameEntry>[
        _game('short', seconds: 60, sessions: 1, lastPlayedMs: 30),
        _game('never', seconds: 0, sessions: 0, lastPlayedMs: 0),
        _game('long', seconds: 3600, sessions: 2, lastPlayedMs: 10),
      ],
      dailyTotals: <String, (int, int)>{
        '2026-07-29': (90, 1),
      },
      now: now,
    );

    expect(aggregate.daily, hasLength(30));
    expect(aggregate.daily.first.dateKey, '2026-06-30');
    expect(aggregate.daily.last.dateKey, '2026-07-29');
    expect(aggregate.daily.last.ms, 90000);
    expect(
      aggregate.byGame.map((GalgameEntry game) => game.id),
      <String>['long', 'short'],
    );
  });
}
