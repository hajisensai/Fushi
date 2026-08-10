import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_merge_engine.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// v82 备份合并换键回归测试（雷区：`_srcBookUidRekey` 双侧 JOIN 断了不会报错，
/// 只会静默零命中——src 行要么原 uid 直插成孤儿、要么 guard 全滤掉）。
///
/// 场景：src / target 两库有**同 book_key** 的书，但各自的本机 uid 互异
/// （uid 是导入时本机生成，跨库必然不同）。merge 后四表（reader_positions
/// LWW / bookmarks dedupe / book_custom_css LWW / revealed_images LWW）的
/// src 行必须全部命中到 **target uid** 键的行上，且不得出现 src uid 键的行。
///
/// 外加 uid 撞库用例：两库 `book_<rowid>_<epoch>` 形 uid 可撞，
/// [_insertMissingEpubBooks] 必须重生成而不是让 partial 唯一索引炸掉整个事务。
///
/// 变异实测（2026-08-10，临时破坏 lib 后确认转红、已还原，零 lib 残留）：
///  - fushi/lib/src/sync/backup_merge_engine.dart 的 `_srcBookUidRekey` 改成
///    裸 `'s.book_uid'`（模拟换键 JOIN 断掉）→ 两用例齐红：换键用例在
///    「reader_positions 不得留下 src uid 孤儿行」处 expected 0 actual 1、
///    撞库用例的进度未命中 book-b 新 uid（getReaderPosition 返回 null）；
///  - `_insertMissingEpubBooks` 的 uid CASE 重生成改成直搬 `s.uid` → 撞库
///    测试转红（merge 抛 UNIQUE constraint failed: epub_books.uid）。
void main() {
  int bookCounter = 0;

  EpubBooksCompanion book(String key, String uid) => EpubBooksCompanion.insert(
        bookKey: key,
        uid: Value(uid),
        title: key,
        epubPath: '/fake/$key.epub',
        extractDir: '/fake/$key-${bookCounter++}',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1000,
      );

  ReaderPositionsCompanion position(
    String bookUid, {
    required int sectionIndex,
    required int updatedAt,
  }) =>
      ReaderPositionsCompanion.insert(
        bookUid: bookUid,
        sectionIndex: sectionIndex,
        normCharOffset: sectionIndex * 1000,
        updatedAt: updatedAt,
      );

  Future<void> addBookmark(
    FushiDatabase db,
    String bookUid, {
    required int sectionIndex,
    required String label,
    required int createdAt,
  }) =>
      db.into(db.bookmarks).insert(BookmarksCompanion.insert(
            bookUid: bookUid,
            sectionIndex: sectionIndex,
            normCharOffset: sectionIndex * 100,
            label: label,
            createdAt: createdAt,
          ));

  /// 在磁盘目录建 src 库（ATTACH 需要真文件），种子回调后关闭，返回 db 路径。
  Future<String> buildSrcDb(
      Future<void> Function(FushiDatabase src) seed) async {
    final Directory srcDir = await Directory.systemTemp.createTemp('rk_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final FushiDatabase src = FushiDatabase(srcDir.path);
    await seed(src);
    await src.close();
    return p.join(srcDir.path, 'fushi.db');
  }

  Future<void> attachAndMerge(FushiDatabase target, String srcDbPath) async {
    final String safe = srcDbPath.replaceAll(r'\', '/').replaceAll("'", "''");
    await target.customStatement("ATTACH DATABASE '$safe' AS mergesrc");
    await BackupMergeEngine(target).merge();
    await target.customStatement('DETACH DATABASE mergesrc');
  }

  Future<int> countWhere(FushiDatabase db, String table, String where) async {
    final QueryRow row = await db
        .customSelect('SELECT COUNT(*) AS c FROM $table WHERE $where')
        .getSingle();
    return row.read<int>('c');
  }

  test('同 book_key 书 uid 互异：四表换键 JOIN 全部命中 target uid 行', () async {
    final String srcDbPath = await buildSrcDb((FushiDatabase src) async {
      await src.insertEpubBook(book('shared', 'src-uid-shared'));
      // LWW 赢方（updatedAt 2000 > target 1000）。
      await src.upsertReaderPosition(
          position('src-uid-shared', sectionIndex: 7, updatedAt: 2000));
      // SRT 域行：键不在 epub_books，COALESCE 照抄合并。
      await src.upsertReaderPosition(
          position('srt-common', sectionIndex: 2, updatedAt: 50));
      // 书签：一条 src 独有 + 一条与 target 完全同 dedupe 键。
      await addBookmark(src, 'src-uid-shared',
          sectionIndex: 1, label: 'from-src', createdAt: 500);
      await addBookmark(src, 'src-uid-shared',
          sectionIndex: 9, label: 'dup', createdAt: 900);
      // css：ch1 src 较新（应赢）、ch2 src 较旧（应输）。
      await src.upsertBookCss('src-uid-shared', 'ch1.css', 'src-css', 2000);
      await src.upsertBookCss('src-uid-shared', 'ch2.css', 'src-old', 500);
      // revealed：img1 双方都有（src 时刻较新）、img2 src 独有。
      await src.markImageRevealed('src-uid-shared', 'img1', 2000);
      await src.markImageRevealed('src-uid-shared', 'img2', 300);
    });

    final FushiDatabase target =
        FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(target.close);
    await target.insertEpubBook(book('shared', 'tgt-uid-shared'));
    await target.upsertReaderPosition(
        position('tgt-uid-shared', sectionIndex: 1, updatedAt: 1000));
    await addBookmark(target, 'tgt-uid-shared',
        sectionIndex: 9, label: 'dup', createdAt: 900);
    await target.upsertBookCss('tgt-uid-shared', 'ch1.css', 'tgt-css', 1000);
    await target.upsertBookCss('tgt-uid-shared', 'ch2.css', 'tgt-new', 3000);
    await target.markImageRevealed('tgt-uid-shared', 'img1', 1000);

    await attachAndMerge(target, srcDbPath);

    // 书本身：同 book_key 不重插。
    expect(await target.getAllEpubBooks(), hasLength(1));

    // ── 雷区总闸：任何表都不得出现 src uid 键的行（换键断了的第一症状）──
    for (final String table in <String>[
      'reader_positions',
      'bookmarks',
      'book_custom_css',
      'revealed_images',
    ]) {
      expect(await countWhere(target, table, "book_uid = 'src-uid-shared'"), 0,
          reason: '$table 不得留下 src uid 孤儿行（换键 JOIN 必须命中）');
    }

    // ── reader_positions：LWW src 赢，落在 target uid 行上 ──
    final ReaderPositionRow? pos =
        await target.getReaderPosition('tgt-uid-shared');
    expect(pos, isNotNull);
    expect(pos!.sectionIndex, 7, reason: 'src updatedAt 2000 > 1000，LWW 赢');
    expect(pos.updatedAt, 2000);
    // SRT 域行照抄键值直等合并。
    final ReaderPositionRow? srt = await target.getReaderPosition('srt-common');
    expect(srt, isNotNull, reason: '非 epub 域行 COALESCE 回落原键合入');
    expect(srt!.sectionIndex, 2);

    // ── bookmarks：dedupe-union，src 行换键落 target uid ──
    final List<QueryRow> bms = await target
        .customSelect(
            "SELECT * FROM bookmarks WHERE book_uid = 'tgt-uid-shared' "
            'ORDER BY created_at')
        .get();
    expect(bms, hasLength(2), reason: 'dup 按 dedupe 键去重，from-src 合入');
    expect(bms.map((QueryRow r) => r.read<String>('label')).toList(),
        <String>['from-src', 'dup']);

    // ── book_custom_css：per {uid, relativePath} LWW 双向 ──
    final List<BookCustomCssRow> cssRows =
        await target.getBookCssRows('tgt-uid-shared');
    expect(cssRows, hasLength(2));
    final BookCustomCssRow ch1 = cssRows
        .singleWhere((BookCustomCssRow r) => r.relativePath == 'ch1.css');
    expect(ch1.content, 'src-css', reason: 'src 2000 > target 1000，src 赢');
    expect(ch1.updatedAt, 2000);
    final BookCustomCssRow ch2 = cssRows
        .singleWhere((BookCustomCssRow r) => r.relativePath == 'ch2.css');
    expect(ch2.content, 'tgt-new', reason: 'target 3000 > src 500，target 保留');
    expect(ch2.updatedAt, 3000);

    // ── revealed_images：union + revealedAt 取较新 ──
    expect(await target.getRevealedImageKeys('tgt-uid-shared'),
        <String>{'img1', 'img2'});
    expect(
        await countWhere(
            target,
            'revealed_images',
            "book_uid = 'tgt-uid-shared' AND image_key = 'img1' "
                'AND revealed_at = 2000'),
        1,
        reason: 'img1 双方都有，revealedAt LWW 刷到 src 的 2000');
  });

  test('uid 撞库：src 新书撞 target 已有 uid，merge 不炸且插入行重生成 uid', () async {
    final String srcDbPath = await buildSrcDb((FushiDatabase src) async {
      await src.insertEpubBook(book('book-b', 'uid-collide-X'));
      // 撞库书自己的子表行：插入后必须跟着重生成的 uid 走，不许错挂到
      // target 里恰好同 uid 的 book-a 上。
      await src.upsertReaderPosition(
          position('uid-collide-X', sectionIndex: 4, updatedAt: 100));
    });

    final FushiDatabase target =
        FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(target.close);
    await target.insertEpubBook(book('book-a', 'uid-collide-X'));

    // 撞上 partial 唯一索引不得炸事务。
    await attachAndMerge(target, srcDbPath);

    final List<EpubBookRow> books = await target.getAllEpubBooks();
    expect(books, hasLength(2), reason: 'book-b 必须插入成功');
    final EpubBookRow bookA =
        books.singleWhere((EpubBookRow b) => b.bookKey == 'book-a');
    final EpubBookRow bookB =
        books.singleWhere((EpubBookRow b) => b.bookKey == 'book-b');
    expect(bookA.uid, 'uid-collide-X', reason: '本库已有书的 uid 不动');
    expect(bookB.uid, isNotEmpty);
    expect(bookB.uid, isNot('uid-collide-X'), reason: '撞库时插入行的 uid 必须本机重生成');
    expect(bookB.uid, matches(RegExp(r'^book_\d+_\d+_m$')),
        reason: '重生成走同命名空间 `book_<srcRowid>_<epoch>_m` 形');

    // 子表行跟着重生成的 uid 走（经 book_key 双侧 JOIN，不受 uid 撞值干扰）。
    final ReaderPositionRow? posB = await target.getReaderPosition(bookB.uid);
    expect(posB, isNotNull, reason: '进度必须命中 book-b 的新 uid');
    expect(posB!.sectionIndex, 4);
    expect(await target.getReaderPosition('uid-collide-X'), isNull,
        reason: 'book-a 无进度——src 行不得错挂到同 uid 值的 book-a 上');
  });
}
