import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';

import 'temp_dir_cleanup.dart';

/// 导入摘要的 **present 判据面必须等于该类别的裁剪面**。
///
/// 这两者原来各写各的：`statistics` 裁 `_statisticsTables` 的 12 张表，判据只数其中
/// 4 张（reading_statistics / video_watch_statistics / mining_statistics /
/// study_segments）；`progress` 裁 reader_positions + bookmarks + `preferences` 里的
/// `audiobook_pos_*`，判据只数前两张。
///
/// 差集里的数据会被**静默删掉**：判据算出 0 → 该类别不进 `summary.present` → 导入 UI
/// 上根本不出现这个开关 → 不进用户的 chosen set → 覆盖导入按「用户没选这个类别」把包里
/// 本来有的行裁掉。用户什么都没做错，数据就没了。
///
/// 所以这里按「判据原来漏掉的那些表」逐张建最小库：**只有那一张表有行**，其余统计/进度
/// 表全空。判据再漏掉其中任何一张，对应用例立刻红。
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bk_presence_');
  });
  tearDown(() async {
    if (dir.existsSync()) await cleanupTempDir(dir);
  });

  Future<BackupContentSummary> summarizeWith(
    Future<void> Function(FushiDatabase db) seed,
  ) async {
    final String dbDir = dir.path;
    final FushiDatabase db = FushiDatabase(dbDir);
    await seed(db);
    final BackupContentSummary summary = await BackupService(
      db: db,
      dbDirectory: dbDir,
      appVersion: '1.0.0',
    ).summarizeLiveContent();
    await db.close();
    return summary;
  }

  group('statistics：判据面覆盖 _statisticsTables 整份清单', () {
    // 原判据漏掉的那些表，每条只写这一张。
    const Map<String, String> missedTables = <String, String>{
      'reading_hourly_logs':
          'INSERT INTO reading_hourly_logs (date_key, hour, reading_time_ms) '
              "VALUES ('2026-09-12', 9, 60000)",
      'video_hourly_logs':
          'INSERT INTO video_hourly_logs (date_key, hour, watch_time_ms) '
              "VALUES ('2026-09-12', 9, 60000)",
      'lookup_mining_counters':
          'INSERT INTO lookup_mining_counters (source_type, date_key, '
              "lookup_count, mine_count) VALUES ('book', '2026-09-12', 3, 1)",
      'mined_sentences':
          'INSERT INTO mined_sentences (source, date_key, created_at) '
              "VALUES ('book', '2026-09-12', 1)",
      'favorite_words':
          'INSERT INTO favorite_words (expression, source_type, date_key, '
              "created_at) VALUES ('猫', 'book', '2026-09-12', 1)",
      'activity_events':
          'INSERT INTO activity_events (event_type, media_type, title, '
              'date_key, timestamp_ms) '
              "VALUES ('read', 'book', 'T', '2026-09-12', 1)",
    };

    missedTables.forEach((String table, String insert) {
      test('只有 $table 有行 → statistics 仍算 present', () async {
        final BackupContentSummary summary = await summarizeWith((
          FushiDatabase db,
        ) async {
          await db.customStatement(insert);
        });
        expect(
          summary.countFor(BackupCategory.statistics),
          greaterThan(0),
          reason: '$table 在 statistics 的裁剪面里，判据就必须数到它——否则这种库被算成'
              '「没有统计数据」，开关不出现，覆盖导入时包里的 $table 行被静默裁掉',
        );
        expect(summary.present, contains(BackupCategory.statistics));
      });
    });
  });

  test('progress：只有 audiobook_pos_* 偏好 → progress 仍算 present', () async {
    final BackupContentSummary summary = await summarizeWith((
      FushiDatabase db,
    ) async {
      await db.customStatement(
        'INSERT INTO preferences (key, value) '
        "VALUES ('audiobook_pos_abc', '12345')",
      );
    });
    expect(
      summary.countFor(BackupCategory.progress),
      greaterThan(0),
      reason: 'progress 的裁剪面含 preferences 里的 audiobook_pos_*；判据漏掉它，'
          '纯有声书用户的听书进度会在覆盖导入时静默丢失',
    );
    expect(summary.present, contains(BackupCategory.progress));
  });

  test('空库：两个类别都不 present（判据不是恒真）', () async {
    final BackupContentSummary summary = await summarizeWith((_) async {});
    expect(summary.countFor(BackupCategory.statistics), 0);
    expect(summary.countFor(BackupCategory.progress), 0);
    expect(summary.present, isNot(contains(BackupCategory.statistics)));
    expect(summary.present, isNot(contains(BackupCategory.progress)));
  });
}
