import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/source_library/book_library_prune.dart';
import 'package:fushi_engine/media/source_library/library_prune_guard.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 书 / 漫画根的扫描对账：`book_library_prune.dart` 的来源索引、存量认领与回收。
///
/// 现象出处：无头服务端扫描书 / 漫画根入库后，用户删掉源 EPUB / 漫画卷，服务端仍保留
/// 原条目——导入把正文拷进 `fushi_books/`，行里记不住源文件，此前书 / 漫画根完全不对账。
void main() {
  late FushiDatabase db;
  late Directory tmp;
  late Directory libraryRoot;
  late int sourceId;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('fushi_book_prune_');
    libraryRoot = Directory(p.join(tmp.path, 'library'))..createSync();
    final Directory documents = Directory(p.join(tmp.path, 'documents'))
      ..createSync();
    enginePaths = FixedEnginePaths(
      documents: documents,
      support: documents,
      temp: documents,
    );
    EpubStorage.debugBaseDirectoryOverride = null;
    sourceId = await db.insertMediaSource(
      MediaSourcesCompanion(
        label: const Value('b'),
        mediaKind: const Value('book'),
        rootPath: Value(libraryRoot.path),
        createdAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  });

  tearDown(() async {
    await db.close();
    EpubStorage.debugBaseDirectoryOverride = null;
    enginePaths = const UninstalledEnginePaths();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 在库根写一个源文件，并插一行「扫描导入」过的书（正文副本落在 fushi_books 下）。
  Future<String> addBook(
    String rel, {
    int? owner = -1,
    String format = 'epub',
    String? epubPath,
    bool writeSource = true,
  }) async {
    final String src = p.join(libraryRoot.path, rel);
    if (writeSource) {
      File(src)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('x');
    }
    final String title = p.basenameWithoutExtension(rel);
    final String extractDir = await EpubStorage.bookDirectory(title);
    File(p.join(extractDir, 'content.opf')).writeAsStringSync('x');
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: title,
        title: title,
        epubPath: epubPath ?? p.basename(rel),
        extractDir: extractDir,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 0,
        format: Value(format),
        sourceId: Value<int?>(owner == -1 ? sourceId : owner),
      ),
    );
    return (await db.getEpubBook(title))!.uid;
  }

  Future<BookSourceIndex> indexOf(Map<String, String> entries) async {
    final BookSourceIndex index = BookSourceIndex.empty(sourceId);
    entries.forEach(index.put);
    await index.save(db);
    return index;
  }

  Future<LibraryPruneReport> prune({
    bool force = false,
    bool dryRun = false,
    Set<String>? baseline,
    LibraryPruneThreshold threshold = const LibraryPruneThreshold(),
  }) => pruneMissingBookRows(
    db: db,
    sourceId: sourceId,
    root: libraryRoot,
    kind: SourceLibraryKind.book,
    baselineBookUids: baseline,
    threshold: threshold,
    force: force,
    dryRun: dryRun,
  );

  test('源 EPUB 删掉 → 回收书行与正文副本；其它书、源文件、墓碑都不动', () async {
    final String keep = await addBook('keep.epub');
    final String drop = await addBook('sub/drop.epub');
    await indexOf(<String, String>{'keep.epub': keep, 'sub/drop.epub': drop});
    final EpubBookRow dropRow = (await db.getEpubBook('drop'))!;
    File(p.join(libraryRoot.path, 'sub', 'drop.epub')).deleteSync();
    Directory(p.join(libraryRoot.path, 'sub')).deleteSync();

    final LibraryPruneReport report = await prune();

    expect(report.skipped, isFalse, reason: '$report');
    expect(report.considered, 2);
    expect(report.deleted, 1);
    expect(await db.getEpubBook('drop'), isNull);
    expect(await db.getEpubBook('keep'), isNotNull);
    expect(Directory(dropRow.extractDir).existsSync(), isFalse);
    expect(File(p.join(libraryRoot.path, 'keep.epub')).existsSync(), isTrue);
    expect(
      await db.select(db.bookTombstones).get(),
      isEmpty,
      reason: '源文件没了是本机事实，不写备份墓碑',
    );
    final BookSourceIndex after = await BookSourceIndex.load(db, sourceId);
    expect(after.entries, <String, String>{'keep.epub': keep});
  });

  test('不属于本来源的书（手动导入 / 别的库根）即便被索引指着也不删', () async {
    await addBook('keep.epub');
    final String manual = await addBook('manual.epub', owner: null);
    final String other = await addBook('other.epub', owner: 999);
    await indexOf(<String, String>{
      'keep.epub': (await db.getEpubBook('keep'))!.uid,
      'manual.epub': manual,
      'other.epub': other,
    });
    File(p.join(libraryRoot.path, 'manual.epub')).deleteSync();
    File(p.join(libraryRoot.path, 'other.epub')).deleteSync();

    final LibraryPruneReport report = await prune();

    expect(report.deleted, 0);
    expect(await db.getEpubBook('manual'), isNotNull);
    expect(await db.getEpubBook('other'), isNotNull);
  });

  test('没被索引认领的本来源书不动（存量行没法判归属）', () async {
    await addBook('keep.epub');
    await addBook('legacy.epub');
    await indexOf(<String, String>{
      'keep.epub': (await db.getEpubBook('keep'))!.uid,
    });
    File(p.join(libraryRoot.path, 'legacy.epub')).deleteSync();

    expect((await prune()).deleted, 0);
    expect(await db.getEpubBook('legacy'), isNotNull);
  });

  test('一本书被两个源认领：删掉一个不算失效，死条目从索引清掉', () async {
    final String uid = await addBook('a/book.epub');
    File(p.join(libraryRoot.path, 'b', 'book.epub'))
      ..parent.createSync()
      ..writeAsStringSync('x');
    File(p.join(libraryRoot.path, 'a', 'other.txt')).writeAsStringSync('x');
    await indexOf(<String, String>{'a/book.epub': uid, 'b/book.epub': uid});
    File(p.join(libraryRoot.path, 'a', 'book.epub')).deleteSync();

    final LibraryPruneReport report = await prune();

    expect(report.deleted, 0);
    expect(await db.getEpubBook('book'), isNotNull);
    expect((await BookSourceIndex.load(db, sourceId)).entries, <String, String>{
      'b/book.epub': uid,
    });
  });

  test('护栏：库根不存在 / 库根里一个源都没有 → 拒绝；force 越过', () async {
    final String uid = await addBook('only.epub');
    await indexOf(<String, String>{'only.epub': uid});
    File(p.join(libraryRoot.path, 'only.epub')).deleteSync();

    final LibraryPruneReport empty = await prune();
    expect(empty.skipped, isTrue);
    expect(empty.skipReason, contains('no book files'));

    libraryRoot.deleteSync(recursive: true);
    final LibraryPruneReport missing = await prune();
    expect(missing.skipped, isTrue);
    expect(missing.skipReason, contains('library root missing'));
    expect(await db.getEpubBook('only'), isNotNull);

    final LibraryPruneReport forced = await prune(force: true);
    expect(forced.deleted, 1);
    expect(await db.getEpubBook('only'), isNull);
  });

  test('护栏：子目录被清空（子挂载点掉线）→ 不可达、不删', () async {
    await addBook('keep.epub');
    final String uid = await addBook('disk2/vol.epub');
    await indexOf(<String, String>{
      'keep.epub': (await db.getEpubBook('keep'))!.uid,
      'disk2/vol.epub': uid,
    });
    File(p.join(libraryRoot.path, 'disk2', 'vol.epub')).deleteSync();

    final LibraryPruneReport report = await prune();

    expect(report.deleted, 0);
    expect(report.unreachable, 1);
    expect(await db.getEpubBook('vol'), isNotNull);
    expect(
      (await BookSourceIndex.load(db, sourceId)).uidOf('disk2/vol.epub'),
      uid,
      reason: '不可达的源条目要留着，挂回来还是同一本',
    );
  });

  test('护栏：失效占比过高 → 拒绝；基线外的书不进分母', () async {
    final Map<String, String> entries = <String, String>{};
    for (int i = 0; i < 12; i++) {
      entries['b$i.epub'] = await addBook('b$i.epub');
    }
    await indexOf(entries);
    for (int i = 1; i < 12; i++) {
      File(p.join(libraryRoot.path, 'b$i.epub')).deleteSync();
    }

    final LibraryPruneReport blocked = await prune();
    expect(blocked.skipped, isTrue);
    expect(blocked.skipReason, contains('exceeds threshold'));
    expect((await db.getEpubBook('b1')), isNotNull);

    final LibraryPruneReport dry = await prune(force: true, dryRun: true);
    expect(dry.missing, 11);
    expect(dry.deleted, 0);
    expect((await db.getEpubBook('b1')), isNotNull);

    final LibraryPruneReport onlyBaseline = await prune(
      baseline: <String>{entries['b0.epub']!, entries['b1.epub']!},
    );
    expect(onlyBaseline.considered, 2);
    expect(onlyBaseline.deleted, 1);
    expect(await db.getEpubBook('b1'), isNull);
    expect(await db.getEpubBook('b2'), isNotNull);
  });

  test('索引里指向已不在库的书的条目会被丢掉', () async {
    final String uid = await addBook('gone.epub');
    await addBook('keep.epub');
    await indexOf(<String, String>{
      'gone.epub': uid,
      'keep.epub': (await db.getEpubBook('keep'))!.uid,
    });
    await db.deleteEpubBook('gone'); // 用户在客户端删了这本书

    await prune();

    expect((await BookSourceIndex.load(db, sourceId)).entries.keys, <String>[
      'keep.epub',
    ]);
  });

  group('adoptExistingBookForSource（存量回填）', () {
    test('无来源 + 同名 + 源文件名一致 → 认领并归到本来源', () async {
      final String uid = await addBook('legacy.epub', owner: null);

      final String? adopted = await adoptExistingBookForSource(
        db: db,
        sourceId: sourceId,
        proposedTitle: 'legacy',
        format: BookFormat.epub,
        sourceFileName: 'legacy.epub',
      );

      expect(adopted, uid);
      expect((await db.getEpubBook('legacy'))!.sourceId, sourceId);
    });

    test('源文件名不一致 / 属于别的来源 / 格式不同 → 不认领', () async {
      await addBook('upload.epub', owner: null, epubPath: 'renamed.epub');
      await addBook('owned.epub', owner: 999);
      await addBook('vol.epub', owner: null, format: 'manga');

      expect(
        await adoptExistingBookForSource(
          db: db,
          sourceId: sourceId,
          proposedTitle: 'upload',
          format: BookFormat.epub,
          sourceFileName: 'upload.epub',
        ),
        isNull,
      );
      expect(
        await adoptExistingBookForSource(
          db: db,
          sourceId: sourceId,
          proposedTitle: 'owned',
          format: BookFormat.epub,
          sourceFileName: 'owned.epub',
        ),
        isNull,
      );
      expect(
        await adoptExistingBookForSource(
          db: db,
          sourceId: sourceId,
          proposedTitle: 'vol',
          format: BookFormat.epub,
          sourceFileName: 'vol.epub',
        ),
        isNull,
      );
      expect((await db.getEpubBook('upload'))!.sourceId, isNull);
    });

    test('漫画按标题 + 格式认领', () async {
      final String uid = await addBook(
        'Vol 1',
        owner: null,
        format: 'manga',
        epubPath: 'manga.json',
        writeSource: false,
      );
      expect(
        await adoptExistingBookForSource(
          db: db,
          sourceId: sourceId,
          proposedTitle: 'Vol 1',
          format: BookFormat.manga,
        ),
        uid,
      );
    });
  });

  test('bookSourceRelPath：正斜杠、库根本身为 .', () {
    expect(
      bookSourceRelPath(
        libraryRoot.path,
        p.join(libraryRoot.path, 'a', 'b.epub'),
      ),
      'a/b.epub',
    );
    expect(bookSourceRelPath(libraryRoot.path, libraryRoot.path), '.');
  });
}
