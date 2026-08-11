import 'package:drift/drift.dart' show QueryRow;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v82 迁移（P3 Stage 1b）定向测试：四张子表（reader_positions / bookmarks /
/// book_custom_css / revealed_images）书键从 book_key(=sanitize(title)) 切到
/// 本机稳定 uid（v81 地基），create-copy-drop-rename。
///
/// 断言面（照 data-layer-stage1b-plan.md 第 6 条）：
///  - epub 行换成对应 uid；
///  - reader_positions 的非 epub 行（SRT 域）照抄原键值（COALESCE 回落）；
///  - book_custom_css 孤儿（无 epub 宿主）被 INNER JOIN 清除；
///  - bookmarks / revealed_images 行数不丢；
///  - idx_bookmarks_book_uid_created 索引重建；
///  - 顺带补 v81 uid 回填断言缺口：旧库升级后 uid 非空且 `book_<rowid>_` 形。
///
/// 变异实测（2026-08-10，临时破坏 lib 后确认转红、已还原，零 lib 残留）：
///  - packages/fushi_core/lib/src/database/database.dart v82 块把
///    reader_positions 回填的 COALESCE(...) 换成裸 rp.book_key（模拟换键
///    JOIN 断掉）→ 两用例齐红：v81 键形用例查 `book_uid='uid-a-stable'` 行
///    No element、v80 连跳用例 book_uid 仍是旧键 'book-old'（≠ 回填 uid）。
void main() {
  /// v81 形旧库：epub_books 已带 uid 列（含真值）+ partial 唯一索引；
  /// 四子表仍是 book_key 键形。user_version=81 → 只走 from<82 步。
  Future<FushiDatabase> openV81Db() async {
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
          rawDb.execute('''
CREATE TABLE reader_positions (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  book_key TEXT NOT NULL UNIQUE,
  section_index INTEGER NOT NULL,
  norm_char_offset INTEGER NOT NULL,
  char_offset INTEGER NOT NULL DEFAULT -1,
  updated_at INTEGER NOT NULL
)''');
          rawDb.execute('''
CREATE TABLE bookmarks (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  book_key TEXT NOT NULL,
  section_index INTEGER NOT NULL,
  norm_char_offset INTEGER NOT NULL,
  label TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  book_title TEXT,
  page_in_chapter INTEGER,
  total_pages_in_chapter INTEGER
)''');
          rawDb.execute('''
CREATE TABLE book_custom_css (
  book_key TEXT NOT NULL,
  relative_path TEXT NOT NULL,
  content TEXT NOT NULL DEFAULT '',
  deleted INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1)),
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (book_key, relative_path)
)''');
          rawDb.execute('''
CREATE TABLE revealed_images (
  book_key TEXT NOT NULL,
  image_key TEXT NOT NULL,
  revealed_at INTEGER NOT NULL,
  PRIMARY KEY (book_key, image_key)
)''');

          rawDb.execute('INSERT INTO epub_books (book_key, uid, title) '
              "VALUES ('book-a', 'uid-a-stable', '书A')");
          // epub 行 + SRT 域行（键不在 epub_books——sanitize 派生键，照抄）。
          rawDb
              .execute('INSERT INTO reader_positions (book_key, section_index, '
                  'norm_char_offset, char_offset, updated_at) '
                  "VALUES ('book-a', 3, 5000, 42, 111)");
          rawDb
              .execute('INSERT INTO reader_positions (book_key, section_index, '
                  'norm_char_offset, char_offset, updated_at) '
                  "VALUES ('srt-book-x', 0, 100, -1, 222)");
          // bookmarks：纯 epub 域，两行（行数不丢断言面）。
          rawDb.execute('INSERT INTO bookmarks (book_key, section_index, '
              'norm_char_offset, label, created_at, book_title) '
              "VALUES ('book-a', 1, 100, '第一章', 10, '书A')");
          rawDb.execute('INSERT INTO bookmarks (book_key, section_index, '
              'norm_char_offset, label, created_at) '
              "VALUES ('book-a', 2, 200, '第二章', 20)");
          // css：一行有宿主 + 一行孤儿（该表历史无 FK 会积孤儿，迁移须清）。
          rawDb.execute('INSERT INTO book_custom_css (book_key, relative_path, '
              'content, deleted, updated_at) '
              "VALUES ('book-a', 'OEBPS/styles/main.css', 'body{color:red}', "
              '0, 10)');
          rawDb.execute('INSERT INTO book_custom_css (book_key, relative_path, '
              'content, deleted, updated_at) '
              "VALUES ('ghost-book', 'a.css', 'x', 0, 20)");
          // revealed_images：旧 FK 保证无孤儿，两行都有宿主。
          rawDb.execute('INSERT INTO revealed_images (book_key, image_key, '
              "revealed_at) VALUES ('book-a', 'OEBPS/img/1.jpg', 10)");
          rawDb.execute('INSERT INTO revealed_images (book_key, image_key, '
              "revealed_at) VALUES ('book-a', 'OEBPS/img/2.jpg', 20)");
          rawDb.execute('PRAGMA user_version = 81');
        },
      ),
    );
    addTearDown(db.close);
    return db;
  }

  Future<int> count(FushiDatabase db, String table) async {
    final QueryRow row =
        await db.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle();
    return row.read<int>('c');
  }

  Future<Set<String>> columnNames(FushiDatabase db, String table) async {
    final List<QueryRow> rows =
        await db.customSelect('PRAGMA table_info($table)').get();
    return rows.map((QueryRow r) => r.read<String>('name')).toSet();
  }

  test('v82：epub 行换 uid、SRT 行照抄原键、css 孤儿清除、行数不丢、索引重建', () async {
    final FushiDatabase db = await openV81Db();

    final QueryRow version =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), db.schemaVersion);
    expect(db.schemaVersion, 85, reason: 'v82 = 四子表书键切 uid');

    // ── reader_positions：跨书族，epub 命中换 uid，SRT 照抄 ──
    expect(await count(db, 'reader_positions'), 2, reason: '迁移零丢行');
    final QueryRow epubPos = await db
        .customSelect('SELECT * FROM reader_positions '
            "WHERE book_uid = 'uid-a-stable'")
        .getSingle();
    expect(epubPos.read<int>('section_index'), 3);
    expect(epubPos.read<int>('norm_char_offset'), 5000);
    expect(epubPos.read<int>('char_offset'), 42);
    expect(epubPos.read<int>('updated_at'), 111);
    final QueryRow srtPos = await db
        .customSelect('SELECT * FROM reader_positions '
            "WHERE book_uid = 'srt-book-x'")
        .getSingle();
    expect(srtPos.read<int>('updated_at'), 222,
        reason: 'JOIN 不上的 SRT 域行照抄原键值，行随迁不丢');

    // ── bookmarks：行数不丢 + 全部换到 uid ──
    expect(await count(db, 'bookmarks'), 2, reason: 'bookmarks 行数不丢');
    final QueryRow bmUidCount = await db
        .customSelect('SELECT COUNT(*) AS c FROM bookmarks '
            "WHERE book_uid = 'uid-a-stable'")
        .getSingle();
    expect(bmUidCount.read<int>('c'), 2, reason: '两条书签全换到宿主 uid');
    final QueryRow bm1 = await db
        .customSelect("SELECT * FROM bookmarks WHERE label = '第一章'")
        .getSingle();
    expect(bm1.read<int>('created_at'), 10);
    expect(bm1.read<String?>('book_title'), '书A');

    // ── book_custom_css：孤儿被清，宿主行换 uid 且内容原样 ──
    expect(await count(db, 'book_custom_css'), 1,
        reason: 'ghost-book 孤儿行被 INNER JOIN 清除');
    final QueryRow css =
        await db.customSelect('SELECT * FROM book_custom_css').getSingle();
    expect(css.read<String>('book_uid'), 'uid-a-stable');
    expect(css.read<String>('relative_path'), 'OEBPS/styles/main.css');
    expect(css.read<String>('content'), 'body{color:red}');

    // ── revealed_images：行数不丢 + 换 uid ──
    expect(await count(db, 'revealed_images'), 2,
        reason: 'revealed_images 行数不丢');
    final QueryRow revUidCount = await db
        .customSelect('SELECT COUNT(*) AS c FROM revealed_images '
            "WHERE book_uid = 'uid-a-stable'")
        .getSingle();
    expect(revUidCount.read<int>('c'), 2);

    // ── 键形：book_key 列消失、book_uid 列到位 ──
    for (final String table in <String>[
      'reader_positions',
      'bookmarks',
      'book_custom_css',
      'revealed_images',
    ]) {
      final Set<String> cols = await columnNames(db, table);
      expect(cols, contains('book_uid'), reason: '$table 应有 book_uid 列');
      expect(cols, isNot(contains('book_key')),
          reason: '$table 的旧 book_key 列应随重建消亡');
    }

    // ── 索引成对重建 ──
    final List<QueryRow> idx = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND name = 'idx_bookmarks_book_uid_created'")
        .get();
    expect(idx, hasLength(1), reason: '书签索引换 book_uid 列后必须在 v82 步内重建');
  });

  test('v80 旧库连跳 v81+v82：uid 回填 book_<rowid>_<epoch> 形并被 v82 换键采用', () async {
    // v81 uid 回填此前无定向断言（plan 第 9④ 条点名的缺口）：造 pre-v81 库
    // （epub_books 无 uid 列），一次升级连走 v81 回填 + v82 换键。
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('PRAGMA foreign_keys = OFF');
          rawDb.execute('''
CREATE TABLE epub_books (
  book_key TEXT NOT NULL PRIMARY KEY,
  title TEXT NOT NULL
)''');
          rawDb.execute('''
CREATE TABLE reader_positions (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  book_key TEXT NOT NULL UNIQUE,
  section_index INTEGER NOT NULL,
  norm_char_offset INTEGER NOT NULL,
  char_offset INTEGER NOT NULL DEFAULT -1,
  updated_at INTEGER NOT NULL
)''');
          rawDb.execute('INSERT INTO epub_books (book_key, title) '
              "VALUES ('book-old', '旧书')");
          rawDb
              .execute('INSERT INTO reader_positions (book_key, section_index, '
                  'norm_char_offset, char_offset, updated_at) '
                  "VALUES ('book-old', 5, 2500, -1, 333)");
          rawDb.execute('PRAGMA user_version = 80');
        },
      ),
    );
    addTearDown(db.close);

    final QueryRow version =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), db.schemaVersion);

    // v81 回填：uid 非空、`book_<rowid>_<epoch秒>` 形（rowid=1）。
    final QueryRow book = await db
        .customSelect("SELECT uid FROM epub_books WHERE book_key = 'book-old'")
        .getSingle();
    final String uid = book.read<String>('uid');
    expect(uid, isNotEmpty, reason: 'v81 回填后 uid 不得为空');
    expect(uid, matches(RegExp(r'^book_1_\d+$')),
        reason: r'回填形 = book_<rowid>_<epoch秒>');

    // partial 唯一索引成对建出。
    final List<QueryRow> idx = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND name = 'idx_epub_books_uid'")
        .get();
    expect(idx, hasLength(1));

    // v82 紧随其后：子表换键必须用「刚回填」的 uid（同一次升级事务内可见）。
    final QueryRow pos =
        await db.customSelect('SELECT * FROM reader_positions').getSingle();
    expect(pos.read<String>('book_uid'), uid, reason: 'v82 换键采用 v81 刚回填的 uid');
    expect(pos.read<int>('section_index'), 5);
    expect(pos.read<int>('updated_at'), 333);
  });
}
