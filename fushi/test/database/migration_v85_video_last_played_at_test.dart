import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v85（BUG-1542）：`video_books` 加 `last_played_at`，给「有进度」这个事实补上
/// 时刻维度。
///
/// 本文件守两件事：
///  1. **加列无损**：存量视频行一条不丢、进度/完成标记逐列不变（丢一行就是丢一部
///     视频的观看记录）。
///  2. **存量回填**：从 `video_watch_statistics` 取每个 bookUid 的
///     `MAX(last_modified)`。这是磁盘上唯一可得的历史近似——不回填的话老库要等每
///     一集都被重看一遍才恢复正确的续播锚点，回填后用户现有库当场就对。回填不到
///     的行留 NULL，选条目层对「全员无时刻」自动退回旧的位置口径。
///
/// 回填**只认有身份的统计行**：v39 前的 NULL-uid 遗留行按 title 键控，跨视频同名
/// 就会互串，拿它回填等于把别的视频的观看时刻按到这一行上。
void _seedV84(dynamic rawDb) {
  // v84 形状的 video_books：**没有** last_played_at。列集照抄升级前真实形状，
  // 多写少写都会让这条迁移在测试里走上一条生产不存在的路径。
  rawDb.execute('''
CREATE TABLE video_books (
  book_uid TEXT NOT NULL,
  title TEXT NOT NULL,
  video_path TEXT NOT NULL,
  subtitle_source TEXT NULL,
  secondary_subtitle_source TEXT NULL,
  subtitle_format TEXT NULL,
  embedded_subtitle_track INTEGER NULL,
  cover_path TEXT NULL,
  last_position_ms INTEGER NOT NULL DEFAULT 0,
  imported_at INTEGER NULL,
  playlist_json TEXT NULL,
  current_episode INTEGER NOT NULL DEFAULT 0,
  audio_track_id TEXT NULL,
  delay_ms INTEGER NOT NULL DEFAULT 0,
  completed_at INTEGER NULL,
  source_id INTEGER NULL,
  stream_spec_json TEXT NULL,
  PRIMARY KEY (book_uid)
)
''');
  rawDb.execute('''
CREATE TABLE video_watch_statistics (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  book_uid TEXT NULL,
  date_key TEXT NOT NULL,
  subtitle_chars INTEGER NOT NULL,
  watch_time_ms INTEGER NOT NULL,
  last_modified INTEGER NOT NULL,
  UNIQUE (book_uid, date_key)
)
''');
  rawDb.execute(
    'INSERT INTO video_books (book_uid, title, video_path, last_position_ms) '
    "VALUES ('video/ep0', 'PV 01', '/abs/ep0.mkv', 24000), "
    "('video/ep1', '第 2 集', '/abs/ep1.mkv', 500), "
    "('video/ep2', '第 3 集', '/abs/ep2.mkv', 0), "
    "('video/dup', '同名片', '/abs/dup.mkv', 700)",
  );
  // ep0：跨两天看过，取更晚的那条（MAX）。
  rawDb.execute(
    'INSERT INTO video_watch_statistics '
    '(title, book_uid, date_key, subtitle_chars, watch_time_ms, last_modified) '
    "VALUES ('PV 01', 'video/ep0', '2026-08-09', 10, 1000, 5000), "
    "('PV 01', 'video/ep0', '2026-08-10', 20, 2000, 9000), "
    "('第 2 集', 'video/ep1', '2026-08-01', 30, 3000, 1000), "
    // v39 前的无身份遗留行：不参与回填（按 title 键控会跨视频互串）。
    "('同名片', NULL, '2026-08-05', 40, 4000, 7000)",
  );
  rawDb.execute('PRAGMA user_version = 84');
}

Future<int?> _lastPlayedAt(FushiDatabase db, String uid) async {
  final QueryRow row = await db.customSelect(
    'SELECT last_played_at FROM video_books WHERE book_uid = ?',
    variables: <Variable<Object>>[Variable<String>(uid)],
  ).getSingle();
  return row.readNullable<int>('last_played_at');
}

void main() {
  FushiDatabase openUpgraded() {
    final FushiDatabase db =
        FushiDatabase.forTesting(NativeDatabase.memory(setup: _seedV84));
    addTearDown(db.close);
    return db;
  }

  test('v84 -> v85：加列无损，存量视频行与进度逐列不变', () async {
    final FushiDatabase db = openUpgraded();

    final QueryRow version =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 87);
    expect(db.schemaVersion, 87);

    final List<VideoBookRow> rows = await db.select(db.videoBooks).get();
    expect(rows, hasLength(4), reason: '迁移丢一行就是丢一部视频的观看记录');
    final VideoBookRow ep0 =
        rows.firstWhere((VideoBookRow r) => r.bookUid == 'video/ep0');
    expect(ep0.title, 'PV 01');
    expect(ep0.videoPath, '/abs/ep0.mkv');
    expect(ep0.lastPositionMs, 24000);
  });

  test('存量回填：取该 bookUid 的 MAX(last_modified)', () async {
    final FushiDatabase db = openUpgraded();
    expect(await _lastPlayedAt(db, 'video/ep0'), 9000,
        reason: '同一视频跨天多条统计行，取最新那条');
    expect(await _lastPlayedAt(db, 'video/ep1'), 1000);
  });

  test('无统计行 → 留 NULL（不编造时刻）', () async {
    final FushiDatabase db = openUpgraded();
    expect(await _lastPlayedAt(db, 'video/ep2'), isNull);
  });

  test('v39 前无身份统计行不参与回填（按 title 键控会跨视频互串）', () async {
    final FushiDatabase db = openUpgraded();
    expect(await _lastPlayedAt(db, 'video/dup'), isNull);
  });

  test('回填后新写入照常覆盖（迁移不是终点，只是起点）', () async {
    final FushiDatabase db = openUpgraded();
    await db.updateVideoBookPosition('video/ep2', 3000, playedAt: 20000);
    expect(await _lastPlayedAt(db, 'video/ep2'), 20000);
  });
}
