import 'package:drift/drift.dart' show Value, QueryRow;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v51 迁移（PDF 阅读器 Phase 1）：epub_books 加 `format` 判别列（'epub'/'pdf'），把 PDF
/// 当「第二种书」复用整套 EpubBooks/书架/进度/删除管线，而非另建平行表。
///
/// 打开一个 user_version=50 的库（v50 shape：epub_books **无** format 列），触发真实
/// `if (from < 51)` 的 `addColumn(epubBooks.format)`，验证：
///  ① 既有行被 SQLite `ADD COLUMN ... DEFAULT 'epub'` 自动回填 'epub'（Never break
///     userspace——老 EPUB 书行为不变）；
///  ② 迁移后能插入并读回 format='pdf' 的新行（PDF 落库路径可用）；
///  ③ user_version 升到当前 schemaVersion（51）。
void main() {
  Future<FushiDatabase> openV50Db() async {
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('PRAGMA foreign_keys = OFF');
          // v50 shape：epub_books 无 format 列（列序对齐 v50 generated schema，
          // 除 format 外全列在场）。
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
  completed_at INTEGER,
  source_id INTEGER
)
''');
          // 一条老 EPUB 书行（无 format 列）。
          rawDb.execute(
            'INSERT INTO epub_books '
            '(book_key, title, epub_path, extract_dir, chapter_count, '
            'chapters_json, imported_at) VALUES '
            "('legacy_book', '旧书', 'legacy.epub', '/books/legacy', 3, "
            "'[]', 1000)",
          );
          rawDb.execute('PRAGMA user_version = 50');
        },
      ),
    );
    addTearDown(db.close);
    return db;
  }

  test('v51：既有 EPUB 行 format 回填为 epub（旧行零破坏）', () async {
    final FushiDatabase db = await openV50Db();
    final EpubBookRow? legacy = await db.getEpubBook('legacy_book');
    expect(legacy, isNotNull, reason: '旧行原样保留');
    expect(legacy!.title, '旧书');
    expect(legacy.format, 'epub',
        reason: 'ADD COLUMN DEFAULT epub 自动回填既有行 = 与旧版行为一致');
    expect(legacy.chapterCount, 3, reason: '其它列原样保留');
  });

  test('v51：可插入并读回 format=pdf 的 PDF 行（完整 schema，走真 insertEpubBook）', () async {
    // 用完整 schema 的 forTesting 库（onCreate 建全表 @v51，含 book_tombstones 等
    // insertEpubBook 依赖的表）——手搭 v50 shape 只有 epub_books，跑不了真插入 DAO。
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final String key = await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'a_pdf_book',
        title: 'PDF 书',
        epubPath: 'document.pdf',
        extractDir: '/books/a_pdf_book',
        chapterCount: 42,
        chaptersJson: '[]',
        importedAt: 2000,
        format: const Value('pdf'),
      ),
    );
    expect(key, 'a_pdf_book');
    final EpubBookRow? pdf = await db.getEpubBook('a_pdf_book');
    expect(pdf, isNotNull);
    expect(pdf!.format, 'pdf', reason: 'PDF 行 format 判别列写穿');
    expect(pdf.chapterCount, 42, reason: 'PDF 页数存 chapterCount');
    expect(pdf.epubPath, 'document.pdf', reason: 'PDF 文件名存 epubPath');

    // 不显式给 format 的插入仍默认 epub（新导入 EPUB 路径不受影响）。
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'default_book',
        title: '默认书',
        epubPath: 'x.epub',
        extractDir: '/books/default_book',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 3000,
      ),
    );
    final EpubBookRow? def = await db.getEpubBook('default_book');
    expect(def!.format, 'epub', reason: '不传 format 默认 epub');
  });

  test('v51：user_version 升到当前 schemaVersion', () async {
    final FushiDatabase db = await openV50Db();
    await db.getEpubBook('legacy_book'); // 触发 open/migrate。
    final QueryRow version =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), db.schemaVersion);
    expect(db.schemaVersion, 76);
  });
}
