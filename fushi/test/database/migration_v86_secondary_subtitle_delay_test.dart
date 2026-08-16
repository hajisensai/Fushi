import 'package:drift/drift.dart' show QueryRow;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v86（TODO-2837 主副字幕分开调轴）：`video_books` 加 `secondary_delay_ms`、
/// `media_collections` 加 `secondary_subtitle_delay_ms`，给副字幕一套独立于主
/// 字幕的两层调轴（镜像 v52 的 delay_ms / subtitle_delay_ms 结构）。
///
/// 本文件守两件事：
///  1. **加列无损**：存量视频行 / 合集行一条不丢、既有调轴值逐列不变。
///  2. **跟随语义**：升级后两列全 NULL = 副字幕继续跟随主字幕调轴——v86 前
///     「主副共用一个 offset」的行为逐字节保留（Never break userspace），任何
///     非 NULL 回填都是在替用户做没做过的决定。
void _seedV85(dynamic rawDb) {
  // v85 形状的 video_books：**没有** secondary_delay_ms。列集照抄升级前真实形状
  // （v84 形状 + v85 的 last_played_at），多写少写都会让这条迁移在测试里走上一条
  // 生产不存在的路径。
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
  last_played_at INTEGER NULL,
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
  // v85 形状的 media_collections：**没有** secondary_subtitle_delay_ms。
  rawDb.execute('''
CREATE TABLE media_collections (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  collection_type TEXT NOT NULL DEFAULT 'collection',
  cover_source TEXT NULL,
  cover_path TEXT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  order_updated_at INTEGER NOT NULL DEFAULT 0,
  anilist_id INTEGER NULL,
  audio_track_id TEXT NULL,
  subtitle_delay_ms INTEGER NULL
)
''');
  // ep0 调过主轨（+800）、ep1 没调过：升级后两行的主轨值必须原样保留。
  rawDb.execute(
    'INSERT INTO video_books (book_uid, title, video_path, delay_ms) '
    "VALUES ('video/ep0', '第 1 集', '/abs/ep0.mkv', 800), "
    "('video/ep1', '第 2 集', '/abs/ep1.mkv', 0)",
  );
  // 合集级调过主轨（-450）：升级后系列级主轨值必须原样保留。
  rawDb.execute(
    'INSERT INTO media_collections (name, created_at, subtitle_delay_ms) '
    "VALUES ('某番剧', 1700000000, -450)",
  );
  rawDb.execute('PRAGMA user_version = 85');
}

Future<int?> _colInt(FushiDatabase db, String sql) async {
  final QueryRow row = await db.customSelect(sql).getSingle();
  return row.readNullable<int>(row.data.keys.single);
}

void main() {
  FushiDatabase openUpgraded() {
    final FushiDatabase db =
        FushiDatabase.forTesting(NativeDatabase.memory(setup: _seedV85));
    addTearDown(db.close);
    return db;
  }

  test('v85 -> v86：加列无损，存量行与既有主轨调轴逐列不变', () async {
    final FushiDatabase db = openUpgraded();

    final QueryRow version =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 87);
    expect(db.schemaVersion, 87);

    final List<VideoBookRow> rows = await db.select(db.videoBooks).get();
    expect(rows, hasLength(2), reason: '迁移丢一行就是丢一部视频的记录');
    final VideoBookRow ep0 =
        rows.firstWhere((VideoBookRow r) => r.bookUid == 'video/ep0');
    expect(ep0.delayMs, 800, reason: '主轨调轴值不许被迁移动到');

    final List<MediaCollectionRow> cols =
        await db.select(db.mediaCollections).get();
    expect(cols, hasLength(1));
    expect(cols.single.subtitleDelayMs, -450, reason: '系列级主轨调轴值不许被迁移动到');
  });

  test('跟随语义：升级后两层副轨列全 NULL = 副字幕继续跟随主字幕（行为不变）', () async {
    final FushiDatabase db = openUpgraded();
    expect(
      await _colInt(db,
          "SELECT secondary_delay_ms FROM video_books WHERE book_uid = 'video/ep0'"),
      isNull,
      reason: '主轨调过（+800）的行也不回填副轨——NULL=跟随，本就等价旧「主副共用」行为',
    );
    expect(
      await _colInt(db,
          "SELECT secondary_delay_ms FROM video_books WHERE book_uid = 'video/ep1'"),
      isNull,
    );
    expect(
      await _colInt(
          db, 'SELECT secondary_subtitle_delay_ms FROM media_collections'),
      isNull,
    );
  });

  test('升级后新写入照常（per-book 与合集级两层写入口）', () async {
    final FushiDatabase db = openUpgraded();
    await db.updateVideoBookSecondaryDelayMs('video/ep0', -250);
    expect(
      await _colInt(db,
          "SELECT secondary_delay_ms FROM video_books WHERE book_uid = 'video/ep0'"),
      -250,
    );
    // 重置为跟随：写回 NULL（不是 0——0 是显式独立值）。
    await db.updateVideoBookSecondaryDelayMs('video/ep0', null);
    expect(
      await _colInt(db,
          "SELECT secondary_delay_ms FROM video_books WHERE book_uid = 'video/ep0'"),
      isNull,
    );

    final List<MediaCollectionRow> cols =
        await db.select(db.mediaCollections).get();
    await db.updateMediaCollectionSecondarySubtitleDelayMs(
        cols.single.id, 1200);
    expect(
      await _colInt(
          db, 'SELECT secondary_subtitle_delay_ms FROM media_collections'),
      1200,
    );
  });
}
