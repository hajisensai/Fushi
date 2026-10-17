import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/sync/paged_book_sync_position.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_compare_dialog.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/sync_manager.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:fushi_engine/sync/ttu_models.dart';

// 页式书（漫画 / PDF）在云通道与对比弹窗里的进度口径。
//
// 页式书 `sectionIndex` 是 0-based 页码、`chaptersJson='[]'`。修复前一律按 EPUB
// 字符表折算：对比弹窗两侧恒显 0.0% 且没有页码；云通道导出 exploredCharCount=0、
// 导入经 fromExploredCharCount 恒落第 1 页 —— 在冲突弹窗里选「远端」会把读到一半
// 的漫画重置回开头。

const String _title = 'ワンピース 01';
const int _pageCount = 200;

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

Future<EpubBookRow> _insertManga(FushiDatabase db) async {
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: sanitizeTtuFilename(_title),
      title: _title,
      epubPath: 'book.epub',
      extractDir: 'x',
      chapterCount: _pageCount,
      chaptersJson: '[]',
      importedAt: 1,
      format: Value(BookFormat.manga.dbValue),
    ),
  );
  return (await db.getAllEpubBooks()).single;
}

Future<void> _setLocalPage(
  FushiDatabase db,
  EpubBookRow book,
  int page, {
  int updatedAt = 2000,
}) async {
  await db.upsertReaderPosition(
    ReaderPositionsCompanion(
      bookUid: Value(book.uid),
      sectionIndex: Value(page),
      normCharOffset: const Value(0),
      updatedAt: Value(updatedAt),
    ),
  );
}

/// 单本书的云文件箱：一个 progress 文件（远端页码 [remotePage]），记录导出写了什么。
class _CloudBackend implements SyncBackend {
  _CloudBackend({this.remotePage});

  final int? remotePage;
  static const int remoteUpdatedAt = 1000;
  TtuProgress? exported;

  static const String _root = 'root';
  static const String _folder = 'folder1';

  SyncFileTrio get _trio => remotePage == null
      ? const SyncFileTrio()
      : SyncFileTrio(
          progress: SyncFileRef(
            id: 'prog1',
            name: 'progress_1_6_${remoteUpdatedAt}_0.0.json',
          ),
        );

  @override
  Future<String> findOrCreateRootFolder() async => _root;
  @override
  String? get cachedRootFolderId => _root;
  @override
  Future<List<SyncFileRef>> listBooks(String rootFolderId) async =>
      <SyncFileRef>[
        SyncFileRef(id: _folder, name: sanitizeTtuFilename(_title)),
      ];
  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) async => _folder;
  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async => _trio;
  @override
  Future<TtuProgress> getProgressFile(String fileId) async => TtuProgress(
    dataId: 0,
    exploredCharCount: remotePage!,
    progress: 0,
    lastBookmarkModified: remoteUpdatedAt,
  );
  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {
    exported = progress;
  }

  @override
  Future<void> putJsonAsset(
    String namespaceId,
    String name,
    Object? json,
  ) async {}
  @override
  void clearCache() {}
  @override
  void restoreCache({
    String? rootFolderId,
    Map<String, String>? titleToFolderId,
  }) {}
  @override
  Map<String, String> get cachedFolderIds => const <String, String>{};
  @override
  void evictFolderId(String folderId) {}
  @override
  void cacheBookFolderIds(List<SyncFileRef> folders) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'unexpected backend call: '
    '${invocation.memberName}',
  );
}

Future<SyncBookResult> _sync(
  FushiDatabase db,
  SyncBackend backend,
  EpubBookRow book,
  SyncDirection direction,
) => SyncManager(db: db, backend: backend).syncBook(
  book: book,
  direction: direction,
  syncStats: false,
  statsSyncMode: StatisticsSyncMode.merge,
  syncAudioBook: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('对比数据：漫画两侧给出页码与按页折算的进度（不再恒 0.0%）', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final EpubBookRow book = await _insertManga(db);
    await _setLocalPage(db, book, 99);

    final List<SyncCompareEntry> entries = await fetchCompareDataForTest(
      db,
      _CloudBackend(remotePage: 49),
    );
    final SyncCompareEntry e = entries.single;

    expect(e.pageCount, _pageCount);
    expect(e.localPage, 99);
    expect(e.remotePage, 49);
    expect(e.localProgress, closeTo(100 / _pageCount, 1e-9));
    expect(e.remoteProgress, closeTo(50 / _pageCount, 1e-9));
  });

  test('云导入：远端页码原样落地，不再把漫画重置到第 1 页', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final EpubBookRow book = await _insertManga(db);
    await _setLocalPage(db, book, 3, updatedAt: 500);

    final SyncBookResult result = await _sync(
      db,
      _CloudBackend(remotePage: 120),
      book,
      SyncDirection.importFromTtu,
    );
    expect(result.direction, SyncResult.imported);
    expect((await db.getReaderPosition(book.uid))!.sectionIndex, 120);
  });

  test('云导入：越界远端页码钳到最后一页', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final EpubBookRow book = await _insertManga(db);

    await _sync(
      db,
      _CloudBackend(remotePage: 999),
      book,
      SyncDirection.importFromTtu,
    );
    expect(
      (await db.getReaderPosition(book.uid))!.sectionIndex,
      _pageCount - 1,
    );
  });

  test('云导出：exploredCharCount 写页码、progress 写按页分数', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final EpubBookRow book = await _insertManga(db);
    await _setLocalPage(db, book, 99);
    final _CloudBackend backend = _CloudBackend();

    final SyncBookResult result = await _sync(
      db,
      backend,
      book,
      SyncDirection.exportToTtu,
    );
    expect(result.direction, SyncResult.exported);
    expect(backend.exported!.exploredCharCount, 99);
    expect(backend.exported!.progress, closeTo(100 / _pageCount, 1e-9));
  });

  test('在线漫画：chapterCount 是章数，不折算全书分数', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final EpubBookRow local = await _insertManga(db);
    expect(pagedSyncPageCount(local), _pageCount);

    const OnlineMangaLibraryEntry online = OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'org.example.src',
      sourceId: '1',
      series: OnlineMangaSeries(
        key: '/manga/x',
        title: 'Fixture',
        raw: <String, Object?>{},
      ),
      chapters: <OnlineMangaChapter>[],
    );
    final EpubBookRow onlineRow = local.copyWith(
      sourceMetadata: Value(online.encode()),
    );
    expect(isPagedSyncBook(onlineRow), isTrue);
    expect(pagedSyncPageCount(onlineRow), isNull);

    final EpubBookRow epub = local.copyWith(format: BookFormat.epub.dbValue);
    expect(isPagedSyncBook(epub), isFalse);
    expect(pagedSyncPageCount(epub), isNull);
    expect(pagedProgressFraction(pageIndex: 5, pageCount: null), isNull);
    expect(clampPagedSyncPageIndex(-3, 10), 0);
    expect(clampPagedSyncPageIndex(42, null), 42);
  });
}
