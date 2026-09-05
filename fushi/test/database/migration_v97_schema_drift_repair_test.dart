import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// v97（schema 漂移修补，BUG-2146）：真实用户库 `user_version = 95`，却缺 v52 /
/// v57 / v87 / v88 四级台阶的产物——五个 `language` 系列列、`media_collections`
/// 的 `audio_track_id` / `subtitle_delay_ms`、两张墓碑表的 `removed_at` 没改名
/// `deleted_at`。版本号已经写高，`from < N` 对它永远不会再进；导入书时
/// `INSERT INTO epub_books (... language)` 直接 no such column。
///
/// 这里从「真实的漂移 v95 库」出发：建当前库 → DROP 掉那七列、把两列改回旧名 →
/// `user_version` 写回 95。只有 95 这个起点能证明修补落在 v97 而不是被并进了
/// 已发布的旧台阶。
void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('fushi_v97_schema_drift');
    dbPath = '${tempDir.path}${Platform.pathSeparator}v95-drifted.db';
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// 建一个真实漂移形状的 v95 库：当前 schema 建满，摘掉四级台阶的产物并把版本写回 95。
  Future<void> seedDriftedV95() async {
    final FushiDatabase fresh =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    // 存量行：迁移必须无损带过去（墓碑行尤其——表要整体重建）。
    await fresh.customStatement(
      'INSERT INTO video_books (book_uid, title, video_path) '
      "VALUES ('video/ep0', '第 1 集', '/abs/ep0.mkv')",
    );
    await fresh.customStatement(
      'INSERT INTO collection_member_tombstones '
      '(collection_name, collection_type, media_type, entry_key, deleted_at) '
      "VALUES ('c', 'manual', 'book', 'k', 1234)",
    );
    await fresh.close();
    final sqlite3.Database raw = sqlite3.sqlite3.open(dbPath);
    try {
      raw.execute('ALTER TABLE epub_books DROP COLUMN language');
      raw.execute(
          'ALTER TABLE dictionary_metadata DROP COLUMN language_override');
      raw.execute('ALTER TABLE video_books DROP COLUMN language');
      raw.execute('ALTER TABLE srt_books DROP COLUMN language');
      raw.execute('ALTER TABLE galgames DROP COLUMN language');
      raw.execute('ALTER TABLE media_collections DROP COLUMN audio_track_id');
      raw.execute(
          'ALTER TABLE media_collections DROP COLUMN subtitle_delay_ms');
      raw.execute('ALTER TABLE collection_member_tombstones '
          'RENAME COLUMN deleted_at TO removed_at');
      raw.execute('ALTER TABLE book_tag_membership_tombstones '
          'RENAME COLUMN deleted_at TO removed_at');
      raw.execute('PRAGMA user_version = 95');
    } finally {
      raw.dispose();
    }
  }

  bool hasColumn(sqlite3.Database db, String table, String column) {
    final sqlite3.ResultSet rows = db.select('PRAGMA table_info($table)');
    return rows.any((sqlite3.Row r) => r['name'] == column);
  }

  test('漂移 v95 库确实缺列（前提自检）', () async {
    await seedDriftedV95();
    final sqlite3.Database probe =
        sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
    try {
      expect(probe.select('PRAGMA user_version').first.values.first, 95);
      expect(hasColumn(probe, 'epub_books', 'language'), isFalse);
      expect(hasColumn(probe, 'media_collections', 'audio_track_id'), isFalse);
      expect(
        hasColumn(probe, 'collection_member_tombstones', 'removed_at'),
        isTrue,
      );
    } finally {
      probe.dispose();
    }
  });

  test('v95 -> v97：七列补齐、墓碑列改名、存量行无损、导入书能落库', () async {
    await seedDriftedV95();

    final FushiDatabase migrated =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    // 线上炸的那一句：epub_books 插入带 language 列。
    await migrated.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'book/x',
        title: 'x',
        epubPath: '/abs/x.epub',
        extractDir: '/abs/x',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1,
      ),
    );
    final List<VideoBookRow> rows =
        await migrated.select(migrated.videoBooks).get();
    expect(rows, hasLength(1), reason: '迁移丢一行就是丢一部视频的记录');
    expect(rows.single.language, isNull);
    final List<CollectionMemberTombstoneRow> tombs =
        await migrated.select(migrated.collectionMemberTombstones).get();
    expect(tombs, hasLength(1));
    expect(tombs.single.deletedAt, 1234, reason: 'removed_at 的值要搬到 deleted_at');
    await migrated.close();

    final sqlite3.Database probe =
        sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
    try {
      expect(probe.select('PRAGMA user_version').first.values.first, 97);
      for (final (String table, String column) in <(String, String)>[
        ('epub_books', 'language'),
        ('dictionary_metadata', 'language_override'),
        ('video_books', 'language'),
        ('srt_books', 'language'),
        ('galgames', 'language'),
        ('media_collections', 'audio_track_id'),
        ('media_collections', 'subtitle_delay_ms'),
        ('collection_member_tombstones', 'deleted_at'),
        ('book_tag_membership_tombstones', 'deleted_at'),
      ]) {
        expect(hasColumn(probe, table, column), isTrue,
            reason: '$table.$column');
      }
      expect(
        hasColumn(probe, 'collection_member_tombstones', 'removed_at'),
        isFalse,
      );
    } finally {
      probe.dispose();
    }
  });

  test('正常 v95 库（列齐全）升到 v97 全部短路 no-op、不报列已存在', () async {
    final FushiDatabase fresh =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    // LazyDatabase 懒打开：不查一次文件里连表都没有。
    await fresh.select(fresh.epubBooks).get();
    await fresh.close();
    final sqlite3.Database raw = sqlite3.sqlite3.open(dbPath);
    try {
      raw.execute('PRAGMA user_version = 95');
    } finally {
      raw.dispose();
    }
    final FushiDatabase migrated =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    await migrated.select(migrated.epubBooks).get();
    await migrated.close();
    final sqlite3.Database probe =
        sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
    try {
      expect(probe.select('PRAGMA user_version').first.values.first, 97);
    } finally {
      probe.dispose();
    }
  });
}
