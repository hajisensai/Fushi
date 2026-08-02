import 'package:drift/drift.dart' show Value, QueryRow;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// v53 迁移（漫画 OCR，第三种书）：epub_books 加 `manga_reading_mode` 覆盖列
/// （null=按页图长宽比自动判定 / 'spread' / 'webtoon'），把漫画当「第三种书」复用整套
/// EpubBooks/书架/进度/删除管线，而非另建平行表。
///
/// 打开一个 user_version=51 的库（v51 shape：epub_books 有 format 列但**无**
/// manga_reading_mode 列），触发真实 `if (from < 53)` 的
/// `addColumn(epubBooks.mangaReadingMode)`，验证：
///  ① 既有行被 SQLite `ADD COLUMN` 自动回填 NULL（Never break userspace——老 EPUB /
///     PDF 书行为不变，mangaReadingMode = null = 自动判定）；
///  ② 迁移后列存在且可写回 'spread' / 'webtoon'（漫画手动覆盖路径可用）；
///  ③ user_version 升到当前 schemaVersion（53）。
void main() {
  Future<HibikiDatabase> openV51Db() async {
    final HibikiDatabase db = HibikiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('PRAGMA foreign_keys = OFF');
          // v51 shape：epub_books 有 format 列但无 manga_reading_mode 列（列序对齐
          // v51 generated schema，除 manga_reading_mode 外全列在场）。
          rawDb.execute('''
CREATE TABLE epub_books (
  book_key TEXT NOT NULL PRIMARY KEY,
  title TEXT NOT NULL,
  author TEXT,
  cover_path TEXT,
  epub_path TEXT NOT NULL,
  extract_dir TEXT NOT NULL,
  chapter_count INTEGER NOT NULL,
  chapters_json TEXT NOT NULL,
  toc_json TEXT,
  source_metadata TEXT,
  imported_at INTEGER NOT NULL,
  format TEXT NOT NULL DEFAULT 'epub',
  completed_at INTEGER,
  source_id INTEGER
)
''');
          // 一条老 EPUB 书行（无 manga_reading_mode 列）。
          rawDb.execute(
            'INSERT INTO epub_books '
            '(book_key, title, epub_path, extract_dir, chapter_count, '
            'chapters_json, imported_at, format) VALUES '
            "('legacy_book', '旧书', 'legacy.epub', '/books/legacy', 3, "
            "'[]', 1000, 'epub')",
          );
          rawDb.execute('PRAGMA user_version = 51');
        },
      ),
    );
    addTearDown(db.close);
    return db;
  }

  test('v53：既有行 mangaReadingMode 回填为 null（旧行零破坏）', () async {
    final HibikiDatabase db = await openV51Db();
    final EpubBookRow? legacy = await db.getEpubBook('legacy_book');
    expect(legacy, isNotNull, reason: '旧行原样保留');
    expect(legacy!.title, '旧书');
    expect(legacy.format, 'epub', reason: 'format 列原样保留');
    expect(legacy.mangaReadingMode, isNull,
        reason: 'ADD COLUMN nullable 自动回填 null = 跟随自动判定，非漫画书无影响');
    expect(legacy.chapterCount, 3, reason: '其它列原样保留');
  });

  test('v53：可插入并读回 format=manga 的漫画行 + mangaReadingMode 覆盖值', () async {
    // 用完整 schema 的 forTesting 库（onCreate 建全表 @v53，含 insertEpubBook
    // 依赖的表）——手搭 v51 shape 只有 epub_books，跑不了真插入 DAO。
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // 漫画行，手动覆盖为 webtoon。
    final String key = await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'a_manga_book',
        title: '漫画书',
        epubPath: '/books/a_manga_book',
        extractDir: '/books/a_manga_book',
        chapterCount: 120,
        chaptersJson: '[]',
        importedAt: 2000,
        format: const Value('manga'),
        mangaReadingMode: const Value('webtoon'),
      ),
    );
    expect(key, 'a_manga_book');
    final EpubBookRow? manga = await db.getEpubBook('a_manga_book');
    expect(manga, isNotNull);
    expect(manga!.format, 'manga', reason: '漫画行 format 判别列写穿');
    expect(manga.mangaReadingMode, 'webtoon', reason: '手动覆盖模式写穿');

    // 不显式给 mangaReadingMode 的漫画行默认 null（= 自动判定）。
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'auto_manga',
        title: '自动判定漫画',
        epubPath: '/books/auto_manga',
        extractDir: '/books/auto_manga',
        chapterCount: 10,
        chaptersJson: '[]',
        importedAt: 3000,
        format: const Value('manga'),
      ),
    );
    final EpubBookRow? auto = await db.getEpubBook('auto_manga');
    expect(auto!.mangaReadingMode, isNull, reason: '不传时默认 null = 跟随自动判定');
  });

  test('v53：user_version 升到当前 schemaVersion', () async {
    final HibikiDatabase db = await openV51Db();
    await db.getEpubBook('legacy_book'); // 触发 open/migrate。
    final QueryRow version =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), db.schemaVersion);
    expect(db.schemaVersion, 68);
  });
}
