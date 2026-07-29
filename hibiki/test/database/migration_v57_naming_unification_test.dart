import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// v57 迁移（命名统一 Phase 4）：三项低风险持久化统一，数据必须逐字节保真。
///
///  ① `video_book_tag_mappings.video_book_uid` → `book_uid`（FK 列与被引列
///     [VideoBooks].bookUid 同名化；FK ON DELETE CASCADE 语义重建后不变）；
///  ② `collection_member_tombstones` / `book_tag_membership_tombstones` 的
///     `removed_at` → `deleted_at`（列 rename，值原样搬运）；
///  ③ `video_books.imported_at`：drift DateTime（Unix 秒存储）→ int 毫秒
///     （×1000 无损转换，NULL 保持 NULL；completed_at 仍是 DateTime 不受影响）。
///
/// 打开一个 user_version=56 的库（v56 shape：旧列名 + imported_at 存秒），触发真实
/// 的 `if (from < 57)` alterTable 阶梯，逐项断言数据无损 + 新列名 + FK 行为。
void main() {
  Future<HibikiDatabase> openV56Db() async {
    final HibikiDatabase db = HibikiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('PRAGMA foreign_keys = OFF');
          // v56 shape：video_books 全列在场，imported_at/completed_at 是 drift
          // DateTime（Unix 秒整数）。media_sources 只作 source_id 的 FK 目标
          // （foreign_key_check 需要父表在场）。
          rawDb.execute('''
CREATE TABLE media_sources (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  label TEXT NOT NULL,
  media_kind TEXT NOT NULL,
  transport TEXT NOT NULL DEFAULT 'local',
  root_path TEXT NOT NULL,
  config_json TEXT,
  media_count INTEGER NOT NULL DEFAULT 0,
  last_scanned_at INTEGER,
  last_scan_error TEXT,
  recursive INTEGER NOT NULL DEFAULT 1,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
)
''');
          rawDb.execute('''
CREATE TABLE book_tags (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  color_value INTEGER NOT NULL DEFAULT 4288585374,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
)
''');
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
  source_id INTEGER REFERENCES media_sources (id) ON DELETE SET NULL,
  stream_spec_json TEXT
)
''');
          rawDb.execute('''
CREATE TABLE video_book_tag_mappings (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  video_book_uid TEXT NOT NULL
    REFERENCES video_books (book_uid) ON DELETE CASCADE,
  tag_id INTEGER NOT NULL REFERENCES book_tags (id) ON DELETE CASCADE,
  added_at INTEGER NOT NULL DEFAULT 0,
  UNIQUE (video_book_uid, tag_id)
)
''');
          rawDb.execute('''
CREATE TABLE collection_member_tombstones (
  collection_name TEXT NOT NULL,
  collection_type TEXT NOT NULL,
  media_type TEXT NOT NULL,
  entry_key TEXT NOT NULL,
  removed_at INTEGER NOT NULL,
  PRIMARY KEY (collection_name, collection_type, media_type, entry_key)
)
''');
          rawDb.execute('''
CREATE TABLE book_tag_membership_tombstones (
  item_key TEXT NOT NULL,
  media_type TEXT NOT NULL,
  tag_name TEXT NOT NULL,
  removed_at INTEGER NOT NULL,
  PRIMARY KEY (item_key, media_type, tag_name)
)
''');
          // 种子：imported_at=1700000000（秒）；completed_at=1700000123（秒）；
          // 第二行 imported_at NULL（旧数据无导入时间，迁移后必须仍是 NULL）。
          rawDb.execute(
            'INSERT INTO video_books '
            '(book_uid, title, video_path, last_position_ms, imported_at, '
            'completed_at) '
            "VALUES ('video/a', '甲', 'Z:/v/a.mkv', 4200, 1700000000, "
            '1700000123)',
          );
          rawDb.execute(
            'INSERT INTO video_books (book_uid, title, video_path) '
            "VALUES ('video/b', '乙', 'Z:/v/b.mkv')",
          );
          rawDb.execute(
            "INSERT INTO book_tags (id, name, created_at) VALUES (1, '收藏', 5)",
          );
          rawDb.execute(
            'INSERT INTO video_book_tag_mappings '
            '(video_book_uid, tag_id, added_at) '
            "VALUES ('video/a', 1, 111)",
          );
          rawDb.execute(
            'INSERT INTO collection_member_tombstones '
            '(collection_name, collection_type, media_type, entry_key, '
            'removed_at) '
            "VALUES ('C', 'collection', 'video', 'gone', 1234)",
          );
          rawDb.execute(
            'INSERT INTO collection_member_tombstones '
            '(collection_name, collection_type, media_type, entry_key, '
            'removed_at) '
            "VALUES ('Dead', 'playlist', '', '', 5678)",
          );
          rawDb.execute(
            'INSERT INTO book_tag_membership_tombstones '
            '(item_key, media_type, tag_name, removed_at) '
            "VALUES ('video/a', 'video', '旧标签', 42)",
          );
          rawDb.execute('PRAGMA user_version = 56');
        },
      ),
    );
    addTearDown(db.close);
    return db;
  }

  Future<Set<String>> columnsOf(HibikiDatabase db, String table) async {
    final rows = await db.customSelect('PRAGMA table_info($table)').get();
    return rows.map((r) => r.read<String>('name')).toSet();
  }

  test('v57：三张表落新列名、旧列名消失，并升到当前 user_version', () async {
    final HibikiDatabase db = await openV56Db();

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), db.schemaVersion);
    expect(db.schemaVersion, 63,
        reason: 'v57 = 命名统一；v58 = 外部媒体自动记录；v59 = 游戏标签；'
            'v60 = 阅读页数；v61 = 合集自有封面；v62 = 每游戏窗口超分档位；'
            'v63 = 清理旧全局超分 pref');

    final Set<String> mapping = await columnsOf(db, 'video_book_tag_mappings');
    expect(mapping, contains('book_uid'));
    expect(mapping, isNot(contains('video_book_uid')),
        reason: '① FK 列与被引列 VideoBooks.bookUid 同名化');

    final Set<String> collTomb =
        await columnsOf(db, 'collection_member_tombstones');
    expect(collTomb, contains('deleted_at'));
    expect(collTomb, isNot(contains('removed_at')), reason: '② 列 rename');

    final Set<String> tagTomb =
        await columnsOf(db, 'book_tag_membership_tombstones');
    expect(tagTomb, contains('deleted_at'));
    expect(tagTomb, isNot(contains('removed_at')), reason: '② 列 rename');
  });

  test('v57 ③：imported_at 秒→毫秒无损（NULL 保持），completed_at 不受影响', () async {
    final HibikiDatabase db = await openV56Db();

    final VideoBookRow? a = await db.getVideoBookByBookUid('video/a');
    expect(a, isNotNull);
    expect(a!.title, '甲');
    expect(a.videoPath, 'Z:/v/a.mkv');
    expect(a.lastPositionMs, 4200, reason: '相邻列不被搬运殃及');
    expect(a.importedAt, 1700000000 * 1000,
        reason: '旧 drift DateTime 存 Unix 秒，×1000 转毫秒');
    expect(a.completedAt?.millisecondsSinceEpoch, 1700000123 * 1000,
        reason: 'completed_at 仍是 DateTime（秒存储），原值往返不变');

    final VideoBookRow? b = await db.getVideoBookByBookUid('video/b');
    expect(b!.importedAt, isNull, reason: 'NULL 不被 ×1000 造出假时间');
  });

  test('v57 ①：映射行值保真，重建后的 FK ON DELETE CASCADE 仍生效', () async {
    final HibikiDatabase db = await openV56Db();

    final List<VideoBookTagMappingRow> rows =
        await db.getAllVideoBookTagMappings();
    expect(rows, hasLength(1));
    expect(rows.single.bookUid, 'video/a');
    expect(rows.single.tagId, 1);
    expect(rows.single.addedAt, 111, reason: 'LWW add 时钟原样搬运');

    // 标签查询链路（join + where 新列）活着。
    final tags = await db.getTagsForVideoBook('video/a');
    expect(tags.single.name, '收藏');

    // 重建表的 FK 子句必须保住 ON DELETE CASCADE：删视频行连坐清映射。
    await db
        .customStatement("DELETE FROM video_books WHERE book_uid = 'video/a'");
    expect(await db.getAllVideoBookTagMappings(), isEmpty,
        reason: '重建后的 FK cascade 行为与 v56 一致');
  });

  test('v57 ②：两张墓碑表值保真、主键/upsert 语义不变', () async {
    final HibikiDatabase db = await openV56Db();

    final List<CollectionMemberTombstoneRow> tombs =
        await db.getAllCollectionMemberTombstones();
    expect(tombs, hasLength(2));
    final CollectionMemberTombstoneRow member =
        tombs.firstWhere((r) => r.entryKey == 'gone');
    expect(member.collectionName, 'C');
    expect(member.deletedAt, 1234, reason: 'removed_at 值原样搬进 deleted_at');
    final CollectionMemberTombstoneRow sentinel = tombs.firstWhere(
        (r) => r.entryKey == HibikiDatabase.collectionTombstoneSentinel);
    expect(sentinel.collectionName, 'Dead');
    expect(sentinel.deletedAt, 5678, reason: '合集级哨兵行同样保真');

    // 主键仍是四元自然键：同键 upsert 刷新时间戳而非加行。
    await db.upsertCollectionMemberTombstone(
      collectionName: 'C',
      collectionType: 'collection',
      mediaType: 'video',
      entryKey: 'gone',
      deletedAt: 9999,
    );
    final List<CollectionMemberTombstoneRow> after =
        await db.getAllCollectionMemberTombstones();
    expect(after, hasLength(2));
    expect(after.firstWhere((r) => r.entryKey == 'gone').deletedAt, 9999);

    // 标签移除墓碑：值保真 + 读 API（LWW 时钟）返回原值。
    final Map<String, int> tagTombs =
        await db.tagTombstonesByName('video/a', MediaKind.video);
    expect(tagTombs, {'旧标签': 42});
  });

  test('v57：fresh 库由 onCreate 直接建出新 shape，可写可读', () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    expect(
        await columnsOf(db, 'video_book_tag_mappings'), contains('book_uid'));
    expect(await columnsOf(db, 'collection_member_tombstones'),
        contains('deleted_at'));
    expect(await columnsOf(db, 'book_tag_membership_tombstones'),
        contains('deleted_at'));

    await db.upsertVideoBook(VideoBooksCompanion.insert(
      bookUid: 'video/x',
      title: 'x',
      videoPath: 'Z:/x.mkv',
      importedAt: const Value<int?>(1700000000000),
    ));
    expect(
        (await db.getVideoBookByBookUid('video/x'))!.importedAt, 1700000000000,
        reason: '新库 importedAt 直接以毫秒写读');

    final int tagId = await db.getOrCreateTagByName('t');
    await db.addTagToVideoBook('video/x', tagId);
    expect((await db.getTagsForVideoBook('video/x')).single.name, 't');
  });
}
