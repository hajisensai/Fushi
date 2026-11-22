// BUG-4960：统计中心总览的 loadStatFacts 在调用方（UI）isolate 上的最长同步段。
//
// 合成大库（文件库，与生产同款 drift 后台连接）：一年多的段 + legacy 四表 + 游玩会话。
// 每种模式跑 5 次，期间主 isolate 上挂一个 1 ms 周期的 Timer，记录相邻两次回调的最大
// 间隔 = 这次加载在主 isolate 上造成的最长阻塞（掉帧的直接量）。
//
// 用法（packages/fushi_engine 下）：
//   dart run benchmark/stat_facts_main_isolate_benchmark.dart [段数=120000]
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Batch, InsertMode, Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/stat_facts.dart';

Future<void> main(List<String> args) async {
  final int segmentCount = args.isEmpty ? 120000 : int.parse(args.first);
  final Directory dir = await Directory.systemTemp.createTemp('stat_bench_');
  final FushiDatabase db = FushiDatabase(dir.path);
  try {
    await _seed(db, segmentCount);
    // 空载对照：同一个 1 ms Timer 什么都不做时的最大间隔（Windows 默认计时器粒度约
    // 15.6 ms，这一行就是测量本身的底噪）。
    final List<int> idle = <int>[];
    for (int run = 0; run < 5; run++) {
      idle.add((await _measureIdle(const Duration(milliseconds: 750))));
    }
    idle.sort();
    stdout.writeln(
      'idle baseline          : max timer gap median ${idle[2] ~/ 1000} ms',
    );
    for (final bool inline in <bool>[true, false]) {
      // 基准要两种执行位置对比（inline = 迁移前的执行位置）。
      // ignore: invalid_use_of_visible_for_testing_member
      debugStatFactsInline = inline;
      final List<int> gaps = <int>[];
      final List<int> walls = <int>[];
      for (int run = 0; run < 6; run++) {
        final (int gapUs, int wallUs, int daily, int sessions) = await _measure(
          db,
        );
        if (run == 0) {
          stdout.writeln(
            '  ${inline ? 'caller isolate' : 'background   '}: '
            '$daily daily facts, $sessions sessions',
          );
          continue; // 首轮热身（库页缓存、原生库加载）。
        }
        gaps.add(gapUs);
        walls.add(wallUs);
      }
      gaps.sort();
      walls.sort();
      stdout.writeln(
        '${inline ? 'caller isolate (inline)' : 'background isolate     '}: '
        'max main-isolate block median ${gaps[2] ~/ 1000} ms '
        '(min ${gaps.first ~/ 1000}, max ${gaps.last ~/ 1000}); '
        'wall median ${walls[2] ~/ 1000} ms',
      );
    }
  } finally {
    await db.close();
    await dir.delete(recursive: true);
  }
}

Future<int> _measureIdle(Duration span) async {
  final Stopwatch tick = Stopwatch()..start();
  int maxGap = 0;
  int last = 0;
  final Timer timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
    final int now = tick.elapsedMicroseconds;
    if (now - last > maxGap) maxGap = now - last;
    last = now;
  });
  await Future<void>.delayed(span);
  timer.cancel();
  return maxGap;
}

Future<(int, int, int, int)> _measure(FushiDatabase db) async {
  final Stopwatch tick = Stopwatch()..start();
  int maxGap = 0;
  int last = 0;
  final Timer timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
    final int now = tick.elapsedMicroseconds;
    if (now - last > maxGap) maxGap = now - last;
    last = now;
  });
  final Stopwatch wall = Stopwatch()..start();
  final StatFacts f = await loadStatFacts(
    db,
    activityLimit: 0,
    includeCounters: true,
  );
  wall.stop();
  // 收尾：让最后一段阻塞也被计到。
  await Future<void>.delayed(const Duration(milliseconds: 5));
  timer.cancel();
  return (maxGap, wall.elapsedMicroseconds, f.daily.length, f.sessions.length);
}

Future<void> _seed(FushiDatabase db, int segmentCount) async {
  final Stopwatch sw = Stopwatch()..start();
  final int profile = await db.resolveActiveProfileId();
  const int day = 86400000;
  final int base = DateTime.utc(2025).millisecondsSinceEpoch;
  final List<StudySegmentsCompanion> rows = <StudySegmentsCompanion>[];
  for (int i = 0; i < segmentCount; i++) {
    final String kind = const <String>['book', 'video', 'game'][i % 3];
    final int start = base + (i ~/ 200) * day + (i % 200) * 300000;
    final DateTime t = DateTime.fromMillisecondsSinceEpoch(start, isUtc: true);
    rows.add(
      StudySegmentsCompanion.insert(
        uid: 's$i',
        deviceId: 'dev${i % 2}',
        mediaKind: kind,
        mediaKey: '$kind${i % 400}',
        title: 'タイトル ${i % 400}',
        startAt: start,
        endAt: start + 240000,
        dateKey: FushiDatabase.statCalendarDayKeyOf(t),
        hour: t.hour,
        durationMs: Value(kind == 'game' ? 0 : 240000),
        chars: Value(i % 700),
        updatedAt: start,
        profileId: Value(profile),
      ),
    );
  }
  for (int i = 0; i < rows.length; i += 5000) {
    final int end = i + 5000 > rows.length ? rows.length : i + 5000;
    await db.batch(
      (Batch b) => b.insertAll(db.studySegments, rows.sublist(i, end)),
    );
  }
  await db.batch((Batch b) {
    for (int d = 0; d < 1500; d++) {
      final String key = FushiDatabase.statCalendarDayKeyOf(
        DateTime.utc(2021).add(Duration(days: d)),
      );
      for (int k = 0; k < 4; k++) {
        b.insert(
          db.readingStatistics,
          ReadingStatisticsCompanion.insert(
            title: 'Legacy $k',
            dateKey: key,
            charactersRead: d,
            readingTimeMs: d * 1000,
            lastStatisticModified: d,
          ),
          mode: InsertMode.insertOrIgnore,
        );
      }
      b.insert(
        db.videoWatchStatistics,
        VideoWatchStatisticsCompanion.insert(
          title: 'Video',
          bookUid: Value('v${d % 30}'),
          dateKey: key,
          subtitleChars: d,
          watchTimeMs: d * 1000,
          lastModified: d,
        ),
        mode: InsertMode.insertOrIgnore,
      );
      for (int h = 0; h < 3; h++) {
        b.insert(
          db.readingHourlyLogs,
          ReadingHourlyLogsCompanion.insert(
            dateKey: key,
            hour: h * 7,
            readingTimeMs: 60000,
          ),
          mode: InsertMode.insertOrIgnore,
        );
      }
    }
    for (int g = 0; g < 2000; g++) {
      final int start = base + g * 7200000;
      b.insert(
        db.galgameSessions,
        GalgameSessionsCompanion.insert(
          gameId: 'game${g % 400}',
          startMs: start,
          endMs: start + 3600000,
          durationSeconds: 3600,
          dateKey: FushiDatabase.statCalendarDayKeyOf(
            DateTime.fromMillisecondsSinceEpoch(start, isUtc: true),
          ),
          profileId: Value(profile),
        ),
      );
    }
  });
  stdout.writeln(
    'seeded $segmentCount segments in ${sw.elapsedMilliseconds} ms',
  );
}
