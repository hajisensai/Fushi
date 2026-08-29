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
///  3. 键控：同名两个视频同一天各占一行（旧唯一键下第二行会撞约束/互串）；
///     遗留 NULL-uid 行与新键控行同 (title, date) 共存互不污染。
///
/// v90 起累加 DAO（addVideoWatchStatistic）已删，legacy 表冻结；第 3 点改用 drift
/// 直插验证唯一键形状（同 uid 二次累计的用例随 DAO 删除，新事实进 study_segments）。
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
          // 统计删除墓碑表（v34 起就在，TODO-1204），最小库补上该表。
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

  /// 直插一行 legacy 观看统计（v90 后 legacy 表本地不再有累加写入面）。
  Future<void> insertWatch(
    FushiDatabase db, {
    required String title,
    required String bookUid,
    required String dateKey,
    required int subtitleChars,
    required int watchTimeMs,
  }) =>
      db.into(db.videoWatchStatistics).insert(
            VideoWatchStatisticsCompanion.insert(
              title: title,
              bookUid: Value(bookUid),
              dateKey: dateKey,
              subtitleChars: subtitleChars,
              watchTimeMs: watchTimeMs,
              lastModified: 1,
            ),
          );

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

  test('v39 后：同名两个视频同一天各占一行（不再互串/撞约束）', () async {
    final FushiDatabase db = await openV38Db();
    await insertWatch(db,
        title: 'Dup',
        dateKey: '2026-07-11',
        subtitleChars: 10,
        watchTimeMs: 1000,
        bookUid: 'video/d1');
    // 旧唯一键 (title, date_key) 下这一行会撞约束；新键 (book_uid, date_key) 各占一行。
    await insertWatch(db,
        title: 'Dup',
        dateKey: '2026-07-11',
        subtitleChars: 20,
        watchTimeMs: 2000,
        bookUid: 'video/d2');
    final List<VideoWatchStatisticRow> rows =
        await db.getAllVideoWatchStatistics();
    final List<VideoWatchStatisticRow> day11 =
        rows.where((r) => r.dateKey == '2026-07-11').toList();
    expect(day11, hasLength(2), reason: '同名不同 uid 各占一行');
    expect(day11.firstWhere((r) => r.bookUid == 'video/d1').watchTimeMs, 1000);
    expect(day11.firstWhere((r) => r.bookUid == 'video/d2').watchTimeMs, 2000);
  });

  test('v39 后：遗留 NULL-uid 行与同 (title, date) 的新键控行共存、互不污染', () async {
    final FushiDatabase db = await openV38Db();
    // 遗留 Dup 行（NULL uid，2026-07-10 watch=120000）原地不动；新式键控行同 title
    // 同日（d1）另起一行——SQLite UNIQUE 视 NULL 互异，不撞约束。
    await insertWatch(db,
        title: 'Dup',
        dateKey: '2026-07-10',
        subtitleChars: 2,
        watchTimeMs: 2000,
        bookUid: 'video/d1');
    final List<VideoWatchStatisticRow> rows =
        (await db.getAllVideoWatchStatistics())
            .where((r) => r.title == 'Dup' && r.dateKey == '2026-07-10')
            .toList();
    expect(rows, hasLength(2));
    expect(rows.firstWhere((r) => r.bookUid == null).watchTimeMs, 120000,
        reason: '遗留行不被新键控行污染');
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
