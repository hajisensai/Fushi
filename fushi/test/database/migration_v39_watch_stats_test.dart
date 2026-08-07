import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v39 迁移：VideoWatchStatistics 加 book_uid（根治同名视频统计互串，用户拍板）。
///
/// 打开一个 user_version=38 的库（旧表 UNIQUE(title,date_key)），触发真实
/// `if (from < 39)`：
///  1. 表重建：唯一键换 (book_uid,date_key)；旧行数据（含 id/累计值）原样保留。
///  2. 回填：title 在 video_books 里唯一 → book_uid 填上；同名多视频 → 保持 NULL
///     （绝不乱猜归属）。
///  3. 键控写穿：同名两个视频同一天各写各行（旧唯一键下第二个会撞约束/互串）；
///     无 uid 的旧式调用只命中遗留 NULL-uid 行。
void main() {
  Future<FushiDatabase> openV38Db() async {
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('PRAGMA foreign_keys = OFF');
          rawDb.execute('''
CREATE TABLE video_books (
  book_uid TEXT NOT NULL PRIMARY KEY,
  title TEXT NOT NULL,
  video_path TEXT NOT NULL,
  subtitle_source TEXT,
  secondary_subtitle_source TEXT,
  subtitle_format TEXT,
  embedded_subtitle_track INTEGER,
  cover_path TEXT,
  last_position_ms INTEGER NOT NULL DEFAULT 0,
  imported_at INTEGER,
  playlist_json TEXT,
  current_episode INTEGER NOT NULL DEFAULT 0,
  audio_track_id TEXT,
  delay_ms INTEGER NOT NULL DEFAULT 0,
  completed_at INTEGER,
  source_id INTEGER,
  stream_spec_json TEXT
)
''');
          // addVideoWatchStatistic 顺带清统计墓碑（TODO-1204），最小库补上该表。
          rawDb.execute('''
CREATE TABLE statistics_tombstones (
  title TEXT NOT NULL,
  source_type TEXT NOT NULL,
  deleted_at INTEGER NOT NULL,
  PRIMARY KEY (title, source_type)
)
''');
          // 旧 shape：无 book_uid 列，UNIQUE(title,date_key)。
          rawDb.execute('''
CREATE TABLE video_watch_statistics (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  date_key TEXT NOT NULL,
  subtitle_chars INTEGER NOT NULL,
  watch_time_ms INTEGER NOT NULL,
  last_modified INTEGER NOT NULL,
  UNIQUE (title, date_key)
)
''');
          // 视频：Unique 唯一同名；Dup 两个视频同名（歧义，回填必须放弃）。
          rawDb.execute(
            'INSERT INTO video_books (book_uid, title, video_path) VALUES '
            "('video/u1', 'Unique', '/v/u1.mkv'), "
            "('video/d1', 'Dup', '/v/d1.mkv'), "
            "('video/d2', 'Dup', '/v/d2.mkv')",
          );
          rawDb.execute(
            'INSERT INTO video_watch_statistics '
            '(title, date_key, subtitle_chars, watch_time_ms, last_modified) '
            "VALUES ('Unique', '2026-07-10', 100, 60000, 1000), "
            "('Dup', '2026-07-10', 200, 120000, 2000), "
            "('Orphan', '2026-07-09', 5, 100, 500)",
          );
          rawDb.execute('PRAGMA user_version = 38');
        },
      ),
    );
    addTearDown(db.close);
    return db;
  }

  test('v39：表重建保数据 + title 唯一匹配回填 uid、同名/孤儿保持 NULL', () async {
    final FushiDatabase db = await openV38Db();
    final List<VideoWatchStatisticRow> rows =
        await db.getAllVideoWatchStatistics();
    expect(rows, hasLength(3), reason: '旧行原样保留');

    final VideoWatchStatisticRow unique =
        rows.firstWhere((r) => r.title == 'Unique');
    expect(unique.bookUid, 'video/u1', reason: 'title 唯一 → 回填 uid');
    expect(unique.subtitleChars, 100);
    expect(unique.watchTimeMs, 60000);
    expect(unique.lastModified, 1000, reason: '累计值/时间戳原样保留');

    final VideoWatchStatisticRow dup = rows.firstWhere((r) => r.title == 'Dup');
    expect(dup.bookUid, isNull, reason: '同名多视频歧义 → 不乱猜，保持 NULL');
    expect(rows.firstWhere((r) => r.title == 'Orphan').bookUid, isNull,
        reason: '无对应视频行 → 保持 NULL');
  });

  test('v39 后：同名两个视频同一天各写各行（不再互串/撞约束）', () async {
    final FushiDatabase db = await openV38Db();
    await db.addVideoWatchStatistic(
      title: 'Dup',
      dateKey: '2026-07-11',
      subtitleChars: 10,
      watchTimeMs: 1000,
      bookUid: 'video/d1',
    );
    await db.addVideoWatchStatistic(
      title: 'Dup',
      dateKey: '2026-07-11',
      subtitleChars: 20,
      watchTimeMs: 2000,
      bookUid: 'video/d2',
    );
    // 各自二次累计仍命中各自的行。
    await db.addVideoWatchStatistic(
      title: 'Dup',
      dateKey: '2026-07-11',
      subtitleChars: 1,
      watchTimeMs: 100,
      bookUid: 'video/d1',
    );
    final List<VideoWatchStatisticRow> rows =
        await db.getAllVideoWatchStatistics();
    final List<VideoWatchStatisticRow> day11 =
        rows.where((r) => r.dateKey == '2026-07-11').toList();
    expect(day11, hasLength(2), reason: '同名不同 uid 各占一行');
    final VideoWatchStatisticRow d1 =
        day11.firstWhere((r) => r.bookUid == 'video/d1');
    expect(d1.watchTimeMs, 1100, reason: '同 uid 同日累计');
    final VideoWatchStatisticRow d2 =
        day11.firstWhere((r) => r.bookUid == 'video/d2');
    expect(d2.watchTimeMs, 2000);
  });

  test('v39 后：无 uid 的旧式调用只命中遗留 NULL-uid 行，不污染新键控行', () async {
    final FushiDatabase db = await openV38Db();
    // 遗留 Dup 行（NULL uid，2026-07-10 watch=120000）继续被旧式调用累计。
    await db.addVideoWatchStatistic(
      title: 'Dup',
      dateKey: '2026-07-10',
      subtitleChars: 1,
      watchTimeMs: 1000,
    );
    // 新式调用同 title 同日（d1）另起一行。
    await db.addVideoWatchStatistic(
      title: 'Dup',
      dateKey: '2026-07-10',
      subtitleChars: 2,
      watchTimeMs: 2000,
      bookUid: 'video/d1',
    );
    final List<VideoWatchStatisticRow> rows =
        (await db.getAllVideoWatchStatistics())
            .where((r) => r.title == 'Dup' && r.dateKey == '2026-07-10')
            .toList();
    expect(rows, hasLength(2));
    expect(rows.firstWhere((r) => r.bookUid == null).watchTimeMs, 121000);
    expect(rows.firstWhere((r) => r.bookUid == 'video/d1').watchTimeMs, 2000);
  });

  test('user_version 升到当前 schemaVersion', () async {
    final FushiDatabase db = await openV38Db();
    await db.getAllVideoWatchStatistics(); // 触发 open/migrate。
    final QueryRow version =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), db.schemaVersion);
  });
}
