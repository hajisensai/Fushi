import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v82 守卫：四张 uid 键子表（reader_positions / bookmarks / book_custom_css /
/// revealed_images）**刻意无 SQL FK**（epub_books.uid 的唯一性是 partial 索引，
/// FK 会 "foreign key mismatch"），删书级联的唯一真相源是 [deleteEpubBook] 的
/// 显式清理。本测试锁死「删书后四表零残留」这条应用层防线——它跟 runtime
/// `foreign_keys` pragma 状态无关，但仍按 plan 第 9⑤ 条显式开 FK
/// （NativeDatabase.memory 默认关，开着跑才与生产 PRAGMA 一致、且顺带证明
/// 级联不是碰巧靠 FK 兜住的）。
///
/// 变异实测（2026-08-10，临时破坏 lib 后确认转红、已还原，零 lib 残留）：
///  - packages/fushi_core/lib/src/database/database_content_misc.part.dart 的
///    deleteEpubBook 把 `if (bookUid != null && bookUid.isNotEmpty)` 显式清理
///    块短路成恒 false → 测试转红（reader_positions 残留 expected 0 actual 1，
///    后续三表同理被同一循环覆盖），证明零残留确实由该显式级联提供、FK 层
///    无兜底（四表本就无 SQL FK）。
void main() {
  Future<FushiDatabase> openDb() async {
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) => rawDb.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    addTearDown(db.close);
    // 自证前提：FK 真开着（memory DB 默认关，setup 回调开启后不许静默失效）。
    final QueryRow fk =
        await db.customSelect('PRAGMA foreign_keys').getSingle();
    expect(fk.read<int>('foreign_keys'), 1,
        reason: '本测试必须在 foreign_keys=ON 下跑（plan 9⑤）');
    return db;
  }

  Future<int> countByUid(FushiDatabase db, String table, String uid) async {
    final QueryRow row = await db.customSelect(
      'SELECT COUNT(*) AS c FROM $table WHERE book_uid = ?',
      variables: <Variable<Object>>[Variable<String>(uid)],
    ).getSingle();
    return row.read<int>('c');
  }

  test('deleteEpubBook：四张 uid 键子表零残留；他书 SRT 域行不误删', () async {
    final FushiDatabase db = await openDb();

    const String uid = 'uid-book-a';
    await db.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: 'book-a',
      uid: const Value(uid),
      title: '书A',
      epubPath: '/fake/book-a.epub',
      extractDir: '/fake/book-a',
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: 1000,
    ));

    // 四表各造行（全部用行 uid 键）。
    await db.upsertReaderPosition(ReaderPositionsCompanion.insert(
      bookUid: uid,
      sectionIndex: 3,
      normCharOffset: 5000,
      charOffset: const Value(42),
      updatedAt: 111,
    ));
    await db.into(db.bookmarks).insert(BookmarksCompanion.insert(
          bookUid: uid,
          sectionIndex: 1,
          normCharOffset: 100,
          label: '第一章',
          createdAt: 10,
        ));
    await db.upsertBookCss(uid, 'OEBPS/styles/main.css', 'body{}', 10);
    await db.markImageRevealed(uid, 'OEBPS/img/1.jpg', 20);

    // 非本书的 SRT 域 reader_positions 行：键不属于 book-a，必须幸存。
    await db.upsertReaderPosition(ReaderPositionsCompanion.insert(
      bookUid: 'srt-other-book',
      sectionIndex: 0,
      normCharOffset: 100,
      updatedAt: 222,
    ));

    final int deleted = await db.deleteEpubBook('book-a');
    expect(deleted, 1, reason: '书行本身删除成功');

    // ── 四表零残留（显式级联，与 FK pragma 无关）──
    for (final String table in <String>[
      'reader_positions',
      'bookmarks',
      'book_custom_css',
      'revealed_images',
    ]) {
      expect(await countByUid(db, table, uid), 0,
          reason: 'deleteEpubBook 后 $table 不得残留该书 uid 的行');
    }

    // ── 相邻不误伤：SRT 域行照旧 ──
    final ReaderPositionRow? srt = await db.getReaderPosition('srt-other-book');
    expect(srt, isNotNull, reason: '非本书键的 SRT 域进度行不得被级联误删');
    expect(srt!.updatedAt, 222);

    expect(await db.getAllEpubBooks(), isEmpty);
    // 再删一次幂等 no-op（无行可删）。
    expect(await db.deleteEpubBook('book-a'), 0);
  });
}
