import 'package:drift/drift.dart' show QueryRow;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v83 迁移（P3 Stage 2）定向测试：shelf_entries / media_collection_items 的
/// epub 域 entryKey 从 bookKey(=sanitize(title)) 切到 epub_books.uid，
/// media_collections.cover_source 的 'epub|<key>' 隐藏载体同步换键，
/// create-copy-drop-rename + INSERT OR IGNORE（v82 同形）。
///
/// 断言面（照 data-layer-stage2-plan.md §6 缺口 1）：
///  - epub 命中行换 uid；
///  - **透传行（epub 无本地行）照抄保留、不清孤儿**——与 v82 子表迁移的
///    INNER JOIN 清孤儿**刻意不同**：合集清单是跨端 union，epub 无主行可能是
///    「替对端转发的远端书归属」（本机没这本书也要保留其成员行），透传行与
///    真孤儿在库内不可区分，清了就是丢对端数据；
///  - srt / video / game 键照抄（mediaType 门控，误换算即数据损坏）；
///  - 撞 PK 脏数据（同 cid 下 bookKey 行与 uid 行并存，换键后收敛同键）经
///    INSERT OR IGNORE 顺带去重，迁移不炸；
///  - cover_source 'epub|<bookKey>' → 'epub|<uid>'，查不上/非 epub 前缀原样；
///  - 行数核对（除去重外零丢行）。
///  - 重入/幂等（§7.4）：uid 值域 `book_<rowid>_<epoch>[_m]` 不落
///    sanitize(title) 值域，重跑 COALESCE 不再命中（病态标题恰为
///    `book_<n>_<n>` 形的碰撞概率忽略，记档于迁移注释）。
///
/// 变异实测（2026-08-10，临时破坏 lib 后确认转红、已还原，零 lib 残留）：
///  - packages/fushi_core/lib/src/database/database.dart v83 块把
///    media_collection_items 回填的 CASE/COALESCE 换成裸 i.entry_key（模拟
///    换键 JOIN 断掉）→ 主用例红：成员键集合仍含 'book-a'、缺 'uid-a'；
///  - 同块 shelf_entries 的 CASE 换成裸 s.entry_key → 主用例红：
///    shelf_entries 无 'uid-a' 行；
///  - cover_source UPDATE 的 LIKE 'epub|%' 改 'epubX|%'（模拟换键不跑）→
///    主用例红：合集甲 cover_source 仍是 'epub|book-a'。
void main() {
  /// v82 形旧库：epub_books 已带 uid 真值（v81/v82 地基），两张合集域表仍是
  /// bookKey 键形。user_version=82 → 只走 from<83 步。
  Future<FushiDatabase> openV82Db() async {
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('PRAGMA foreign_keys = OFF');
          rawDb.execute('''
CREATE TABLE epub_books (
  book_key TEXT NOT NULL PRIMARY KEY,
  uid TEXT NOT NULL DEFAULT '',
  title TEXT NOT NULL
)''');
          rawDb.execute('CREATE UNIQUE INDEX idx_epub_books_uid '
              "ON epub_books (uid) WHERE uid != ''");
          rawDb.execute('CREATE TABLE series (id INTEGER NOT NULL PRIMARY KEY '
              'AUTOINCREMENT, name TEXT NOT NULL)');
          rawDb.execute('''
CREATE TABLE shelf_entries (
  media_type TEXT NOT NULL,
  entry_key TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  series_id INTEGER REFERENCES series (id) ON DELETE SET NULL,
  PRIMARY KEY (media_type, entry_key)
)''');
          rawDb.execute('''
CREATE TABLE media_collections (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  collection_type TEXT NOT NULL DEFAULT 'collection',
  cover_source TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL DEFAULT 0
)''');
          rawDb.execute('''
CREATE TABLE media_collection_items (
  collection_id INTEGER NOT NULL
    REFERENCES media_collections (id) ON DELETE CASCADE,
  media_type TEXT NOT NULL,
  entry_key TEXT NOT NULL,
  sort_index INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (collection_id, media_type, entry_key)
)''');

          rawDb.execute('INSERT INTO epub_books (book_key, uid, title) '
              "VALUES ('book-a', 'uid-a', '书A'), ('book-b', 'uid-b', '书B')");

          // shelf_entries：epub 命中 / epub 透传（无本地书）/ 三个非 epub 域。
          rawDb.execute('INSERT INTO shelf_entries '
              '(media_type, entry_key, sort_order) VALUES '
              "('epub', 'book-a', 5), "
              "('epub', 'ghost-key', 7), "
              "('srt', 'srt-1', 1), "
              "('video', 'vid-1', 2), "
              "('game', 'game-1', 3)");

          rawDb.execute('INSERT INTO media_collections '
              '(id, name, collection_type, cover_source, sort_order, '
              'created_at) VALUES '
              "(1, '甲', 'collection', 'epub|book-a', 0, 100), "
              "(2, '乙', 'playlist', 'epub|ghost-key', 1, 200), "
              "(3, '丙', 'collection', 'video|vid-1', 2, 300)");

          // 合集甲：epub 命中行 + **撞 PK 脏数据**（同 cid 下 bookKey 行与
          // uid 行并存，换键后同为 uid-a）+ 透传行 + 四 kind 混排。
          rawDb.execute('INSERT INTO media_collection_items '
              '(collection_id, media_type, entry_key, sort_index) VALUES '
              "(1, 'epub', 'book-a', 0), "
              "(1, 'epub', 'uid-a', 1), "
              "(1, 'epub', 'ghost-key', 2), "
              "(1, 'srt', 'srt-1', 3), "
              "(1, 'video', 'vid-1', 4), "
              "(1, 'game', 'game-1', 5), "
              "(2, 'epub', 'book-b', 0)");
          rawDb.execute('PRAGMA user_version = 82');
        },
      ),
    );
    addTearDown(db.close);
    return db;
  }

  Future<int> count(FushiDatabase db, String table, [String? where]) async {
    final QueryRow row = await db
        .customSelect('SELECT COUNT(*) AS c FROM $table'
            '${where == null ? '' : ' WHERE $where'}')
        .getSingle();
    return row.read<int>('c');
  }

  test('v83：epub 命中换 uid、透传照抄不清、非 epub 照抄、撞 PK 去重、cover 换键、行数核对', () async {
    final FushiDatabase db = await openV82Db();

    final QueryRow version =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), db.schemaVersion);
    expect(db.schemaVersion, 87,
        reason: 'v83 = shelf_entries / media_collection_items epub 键切 uid');

    // ── shelf_entries：epub 命中换 uid、透传照抄、非 epub 照抄、零丢行 ──
    expect(await count(db, 'shelf_entries'), 5, reason: 'shelf_entries 零丢行');
    final QueryRow shelfEpub = await db
        .customSelect('SELECT sort_order FROM shelf_entries '
            "WHERE media_type = 'epub' AND entry_key = 'uid-a'")
        .getSingle();
    expect(shelfEpub.read<int>('sort_order'), 5, reason: 'epub 命中行换 uid，负载列原样');
    expect(
        await count(db, 'shelf_entries',
            "media_type = 'epub' AND entry_key = 'book-a'"),
        0,
        reason: '旧 bookKey 键形不得残留');
    // 透传行照抄**不清**——与 v82 清孤儿刻意不同：epub 无主行可能是「替对端
    // 转发」的远端书归属（跨端 union），与真孤儿在库内不可区分，清了丢数据。
    expect(
        await count(db, 'shelf_entries',
            "media_type = 'epub' AND entry_key = 'ghost-key'"),
        1,
        reason: '透传行（epub 无本地书）必须照抄保留');
    for (final (String kind, String key) in <(String, String)>[
      ('srt', 'srt-1'),
      ('video', 'vid-1'),
      ('game', 'game-1'),
    ]) {
      expect(
          await count(db, 'shelf_entries',
              "media_type = '$kind' AND entry_key = '$key'"),
          1,
          reason: '$kind 键天然稳定，必须照抄（误换算即数据损坏）');
    }

    // ── media_collection_items：换键 + INSERT OR IGNORE 去重 ──
    final List<QueryRow> c1 = await db
        .customSelect('SELECT media_type, entry_key '
            'FROM media_collection_items WHERE collection_id = 1')
        .get();
    expect(
      c1
          .map((QueryRow r) =>
              '${r.read<String>('media_type')}|${r.read<String>('entry_key')}')
          .toSet(),
      <String>{
        'epub|uid-a',
        'epub|ghost-key',
        'srt|srt-1',
        'video|vid-1',
        'game|game-1',
      },
      reason: 'epub 命中换 uid、透传照抄、非 epub 照抄',
    );
    expect(c1, hasLength(5),
        reason: '撞 PK 脏数据（book-a 行与 uid-a 行并存）换键后收敛同键，'
            'INSERT OR IGNORE 去重为一行（6→5）');
    expect(
        await count(db, 'media_collection_items',
            "collection_id = 2 AND entry_key = 'uid-b'"),
        1,
        reason: '合集乙的 epub 命中行换 uid');
    expect(await count(db, 'media_collection_items'), 6,
        reason: '总行数 7→6：仅撞 PK 去重减一行，其余零丢');

    // ── cover_source 隐藏载体同步换键 ──
    Future<String?> coverOf(int id) async => (await db
            .customSelect(
                'SELECT cover_source FROM media_collections WHERE id = $id')
            .getSingle())
        .read<String?>('cover_source');
    expect(await coverOf(1), 'epub|uid-a',
        reason: 'epub 借用封面键与成员行同律换 uid（漏了 = 封面静默回退占位）');
    expect(await coverOf(2), 'epub|ghost-key',
        reason: '查不上的 epub 封面键照抄（透传/游离），EXISTS 门控不置 NULL');
    expect(await coverOf(3), 'video|vid-1', reason: '非 epub 前缀原样直搬');
  });
}
