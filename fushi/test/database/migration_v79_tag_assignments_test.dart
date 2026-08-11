import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v79 迁移（五张标签映射表合一，2026-08 数据层重构·用户拍板）：
/// book/srt/video/collection/galgame *_tag_mappings → tag_assignments。
///  - epub/video：entry_key 与 added_at 原样平移；
///  - srt：JOIN srt_books 换跨设备稳定的 uid（孤儿映射 JOIN 天然丢弃）；
///  - collection：id 字符串化；game：id 原样；三者旧表无 added_at 落 0；
///  - 五张旧表 DROP。
void main() {
  Future<FushiDatabase> openV78Db({bool legacyVideoUidColumn = false}) async {
    final String videoUidColumn =
        legacyVideoUidColumn ? 'video_book_uid' : 'book_uid';
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('PRAGMA foreign_keys = OFF');
          rawDb.execute('''
CREATE TABLE book_tags (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  color_value INTEGER NOT NULL DEFAULT 0xFF9E9E9E,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
)
''');
          rawDb.execute('''
CREATE TABLE srt_books (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  uid TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  srt_path TEXT NOT NULL,
  imported_at INTEGER NOT NULL,
  book_key TEXT NOT NULL DEFAULT ''
)
''');
          rawDb.execute('''
CREATE TABLE book_tag_mappings (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  book_key TEXT NOT NULL,
  tag_id INTEGER NOT NULL,
  added_at INTEGER NOT NULL DEFAULT 0,
  UNIQUE (book_key, tag_id)
)
''');
          rawDb.execute('''
CREATE TABLE srt_book_tag_mappings (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  srt_book_id INTEGER NOT NULL,
  tag_id INTEGER NOT NULL,
  UNIQUE (srt_book_id, tag_id)
)
''');
          rawDb.execute('''
CREATE TABLE video_book_tag_mappings (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  $videoUidColumn TEXT NOT NULL,
  tag_id INTEGER NOT NULL,
  added_at INTEGER NOT NULL DEFAULT 0,
  UNIQUE ($videoUidColumn, tag_id)
)
''');
          rawDb.execute('''
CREATE TABLE collection_tag_mappings (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  collection_id INTEGER NOT NULL,
  tag_id INTEGER NOT NULL,
  UNIQUE (collection_id, tag_id)
)
''');
          rawDb.execute('''
CREATE TABLE galgame_tag_mappings (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  game_id TEXT NOT NULL,
  tag_id INTEGER NOT NULL,
  UNIQUE (game_id, tag_id)
)
''');
          rawDb.execute(
              "INSERT INTO book_tags (id, name, created_at) VALUES (1, '收藏', 1)");
          rawDb.execute(
              'INSERT INTO srt_books (id, uid, title, srt_path, imported_at) '
              "VALUES (7, 'srt/u1', '有声书', '/a.srt', 1)");
          rawDb.execute(
              'INSERT INTO book_tag_mappings (book_key, tag_id, added_at) '
              "VALUES ('BookA', 1, 111)");
          rawDb.execute(
              'INSERT INTO srt_book_tag_mappings (srt_book_id, tag_id) '
              'VALUES (7, 1)');
          // 孤儿 srt 映射（srt_books 无 id=99 行）：JOIN 丢弃，不迁移。
          rawDb.execute(
              'INSERT INTO srt_book_tag_mappings (srt_book_id, tag_id) '
              'VALUES (99, 1)');
          rawDb.execute('INSERT INTO video_book_tag_mappings '
              '($videoUidColumn, tag_id, added_at) '
              "VALUES ('video/v1', 1, 222)");
          rawDb.execute(
              'INSERT INTO collection_tag_mappings (collection_id, tag_id) '
              'VALUES (42, 1)');
          rawDb.execute('INSERT INTO galgame_tag_mappings (game_id, tag_id) '
              "VALUES ('173000000', 1)");
          rawDb.execute('PRAGMA user_version = 78');
        },
      ),
    );
    addTearDown(db.close);
    return db;
  }

  test('v79：五表搬移零丢行（孤儿除外）、键形正确、旧表 DROP', () async {
    final FushiDatabase db = await openV78Db();

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), db.schemaVersion);
    expect(db.schemaVersion, 85);

    final List<TagAssignmentRow> rows = await db.getAllTagAssignments();
    expect(rows, hasLength(5), reason: '5 张表各 1 行有效映射（孤儿 srt 行丢弃）');

    TagAssignmentRow byKind(String kind) =>
        rows.singleWhere((TagAssignmentRow r) => r.mediaKind == kind);
    expect(byKind('epub').entryKey, 'BookA');
    expect(byKind('epub').addedAt, 111, reason: 'add 时钟原样平移');
    expect(byKind('srt').entryKey, 'srt/u1', reason: 'int id 换跨设备稳定 uid');
    expect(byKind('video').entryKey, 'video/v1');
    expect(byKind('video').addedAt, 222);
    expect(byKind('collection').entryKey, '42', reason: 'id 字符串化');
    expect(byKind('game').entryKey, '173000000');
    expect(byKind('game').addedAt, 0, reason: '旧表无时钟落 0（最古 add）');

    for (final String old in <String>[
      'book_tag_mappings',
      'srt_book_tag_mappings',
      'video_book_tag_mappings',
      'collection_tag_mappings',
      'galgame_tag_mappings',
    ]) {
      final rows = await db.customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
          variables: [Variable<String>(old)]).get();
      expect(rows, isEmpty, reason: '旧表 $old 已 DROP');
    }
  });

  test('v79：兼容未落 v57 改名、仍使用 video_book_uid 的真实旧库', () async {
    final FushiDatabase db = await openV78Db(legacyVideoUidColumn: true);

    final List<TagAssignmentRow> rows = await db.getAllTagAssignments();
    final TagAssignmentRow video = rows.singleWhere(
      (TagAssignmentRow row) => row.mediaKind == 'video',
    );
    expect(video.entryKey, 'video/v1');
    expect(video.addedAt, 222);
    final oldTable = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name='video_book_tag_mappings'",
        )
        .get();
    expect(oldTable, isEmpty, reason: '旧列数据搬完后才能 DROP 遗留映射表');
  });

  test('v79 后：五 kind 走同一张表读写，跨 kind 互不串', () async {
    final FushiDatabase db = await openV78Db();

    expect((await db.getTagsForBook('BookA')).single.name, '收藏');
    expect((await db.getTagsForSrtBook('srt/u1')).single.name, '收藏');
    expect((await db.getTagsForVideoBook('video/v1')).single.name, '收藏');
    expect((await db.getTagsForCollection(42)).single.name, '收藏');
    expect((await db.getTagsForGame('173000000')).single.name, '收藏');
    expect(await db.countBooksForTag(1), 4,
        reason: 'epub+srt+video+game 计入，合集是容器不计');
  });

  test('fresh 库由 onCreate 直接建出 tag_assignments，五 kind API 全通', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final int tagId = await db.getOrCreateTagByName('T');
    await db.addTagToBook('bk', tagId);
    await db.addTagToSrtBook('su', tagId);
    await db.addTagToVideoBook('vu', tagId);
    await db.addTagToCollection(3, tagId);
    await db.addTagToGame('g1', tagId);
    expect(await db.getAllTagAssignments(), hasLength(5));
    expect(
        (await db.getAllTagAssignments())
            .every((TagAssignmentRow r) => r.addedAt > 0),
        isTrue,
        reason: 'v79 拍板：五 kind 统一记 addedAt');
  });

  test(
      'review5-2 回归：FK ON 下悬空 tag_id 不炸升级——过滤丢弃而非 abort '
      '（真实迁移跑在 PRAGMA foreign_keys=ON，OR IGNORE 压不住 FK 违规；'
      'pre-v10 FK-off 时代的野库确有孤儿映射行）', () async {
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          // 刻意 FK ON——与生产连接一致，别让 fixture 遮住 FK 崩（review5-2
          // 点名旧 fixture 的 OFF 是结构性盲区）。
          rawDb.execute('PRAGMA foreign_keys = ON');
          rawDb.execute('''
CREATE TABLE book_tags (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  color_value INTEGER NOT NULL DEFAULT 0xFF9E9E9E,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
)
''');
          rawDb.execute('''
CREATE TABLE galgame_tag_mappings (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  game_id TEXT NOT NULL,
  tag_id INTEGER NOT NULL,
  UNIQUE (game_id, tag_id)
)
''');
          rawDb.execute(
              "INSERT INTO book_tags (id, name, created_at) VALUES (1, 'T', 1)");
          rawDb.execute('INSERT INTO galgame_tag_mappings (game_id, tag_id) '
              "VALUES ('g-live', 1)");
          // 悬空行：tag_id=99 无 book_tags 行（旧表无 FK，插得进去）。
          rawDb.execute('INSERT INTO galgame_tag_mappings (game_id, tag_id) '
              "VALUES ('g-orphan', 99)");
          rawDb.execute('PRAGMA user_version = 78');
        },
      ),
    );
    addTearDown(db.close);

    // 打开即触发迁移；悬空行被 WHERE tag_id IN (SELECT id FROM book_tags)
    // 过滤丢弃，有效行照常搬移，升级不 abort。
    final List<TagAssignmentRow> rows = await db.getAllTagAssignments();
    expect(rows, hasLength(1), reason: '悬空行丢弃、有效行保留');
    expect(rows.single.entryKey, 'g-live');
  });
}
