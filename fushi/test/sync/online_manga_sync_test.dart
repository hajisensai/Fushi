// BUG-4337（反馈 tHFnpAFrX9）：经 Mihon 扩展源（Keiyoushi / Rawkuma）收进书架的在线
// 漫画在云通道「立即同步」恒失败，且用户看不到任何原因。
//
// 根因：在线漫画的 `chaptersJson` 存的是**章节清单**（`OnlineMangaChapter.toJson`，
// 只有 key / name / raw…，没有 `characters`），而 `_syncBookProgress` 不分格式地
// `parseChaptersJson(book.chaptersJson)`，在 `m['characters'] as int` 上抛 TypeError；
// syncBook 把它收进 `SyncBookResult.error`，对比弹窗只 `developer.log`、SnackBar 只报
// 书名就关框——用户日志里没有、界面上也没有原因。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/sync/paged_book_sync_position.dart';
import 'package:fushi/src/sync/position_converter.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_compare_dialog.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/sync_manager.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/ttu_models.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/sync_compare_fixture.dart';

const String _title = 'Mieruko-chan';

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

const List<OnlineMangaChapter> _chapters = <OnlineMangaChapter>[
  OnlineMangaChapter(
    key: '/manga/mieruko-chan/chapter-2',
    name: 'Chapter 2',
    raw: <String, Object?>{'url': '/manga/mieruko-chan/chapter-2'},
  ),
  OnlineMangaChapter(
    key: '/manga/mieruko-chan/chapter-1',
    name: 'Chapter 1',
    raw: <String, Object?>{'url': '/manga/mieruko-chan/chapter-1'},
  ),
];

const OnlineMangaLibraryEntry _entry = OnlineMangaLibraryEntry(
  runtime: OnlineMangaRuntimeKind.mihon,
  extensionPackage: 'eu.kanade.tachiyomi.extension.en.rawkuma',
  sourceId: '1',
  series: OnlineMangaSeries(
    key: '/manga/mieruko-chan',
    title: _title,
    raw: <String, Object?>{},
  ),
  chapters: _chapters,
);

const String _bookKey = 'online-manga-mihon-rawkuma-mieruko';

/// 与 `OnlineMangaLibraryService.add` 写的行同形：format=manga、chaptersJson 是章节
/// 清单、sourceMetadata 是在线条目、extractDir 只有占位 manga.json（无页图）。
Future<EpubBookRow> _insertOnlineManga(FushiDatabase db) async {
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: _bookKey,
      title: _title,
      epubPath: 'manga.json',
      extractDir: '/nonexistent/online-manga/$_bookKey',
      chapterCount: _chapters.length,
      chaptersJson: jsonEncode(<Map<String, Object?>>[
        for (final OnlineMangaChapter c in _chapters) c.toJson(),
      ]),
      sourceMetadata: Value<String?>(_entry.encode()),
      importedAt: 1,
      format: Value<String>(BookFormat.manga.dbValue),
    ),
  );
  return (await db.getEpubBook(_bookKey))!;
}

Future<void> _setLocalPage(
  FushiDatabase db,
  EpubBookRow book,
  int page, {
  int updatedAt = 2000,
}) => db.upsertReaderPosition(
  ReaderPositionsCompanion(
    bookUid: Value<String>(book.uid),
    sectionIndex: Value<int>(page),
    normCharOffset: const Value<int>(0),
    updatedAt: Value<int>(updatedAt),
  ),
);

/// 单本书的云文件箱。[failProgressUpload] 让进度上传抛错（验证失败可见性）。
class _CloudBackend implements SyncBackend {
  _CloudBackend({this.remotePage, this.failProgressUpload = false});

  final int? remotePage;
  final bool failProgressUpload;
  static const int remoteUpdatedAt = 1000;
  TtuProgress? exported;

  static const String _root = 'root';
  static const String _folder = 'folder1';

  @override
  Future<String> findOrCreateRootFolder() async => _root;
  @override
  String? get cachedRootFolderId => _root;
  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) async => _folder;
  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async =>
      remotePage == null
      ? const SyncFileTrio()
      : SyncFileTrio(
          progress: SyncFileRef(
            id: 'prog1',
            name: 'progress_1_6_${remoteUpdatedAt}_0.0.json',
          ),
        );
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
    if (failProgressUpload) throw StateError('progress upload refused');
    exported = progress;
  }

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
    'unexpected backend call: ${invocation.memberName}',
  );
}

/// 对比弹窗用：远端没有这本书（「No data」），进度上传被拒。
class _FailingUploadCompareBackend extends FakeCompareBackend {
  _FailingUploadCompareBackend() : super(<String, RemoteBookFixture>{});

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) async => 'f-new';

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async => throw StateError('progress upload refused');
}

Future<SyncBookResult> _sync(
  FushiDatabase db,
  SyncBackend backend,
  EpubBookRow book,
  SyncDirection? direction,
) => SyncManager(db: db, backend: backend).syncBook(
  book: book,
  direction: direction,
  syncStats: false,
  statsSyncMode: StatisticsSyncMode.merge,
  syncAudioBook: false,
);

Iterable<ErrorLogEntry> _syncLogEntriesFor(String bookKey) => ErrorLogService
    .instance
    .entries
    .where((ErrorLogEntry e) => e.error.contains('book=$bookKey'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('根因：在线漫画的章节清单不是字符表，同步走 syncChapterCharTable 不解析', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final EpubBookRow book = await _insertOnlineManga(db);

    // 旧路径：按字符表解析章节清单必抛（这就是「立即同步」恒失败的那一下）。
    expect(
      () => parseChaptersJson(book.chaptersJson),
      throwsA(isA<TypeError>()),
    );
    expect(syncChapterCharTable(book), isEmpty);
    expect(syncBookSourceKind(book), 'online-manga:mihon');
  });

  test('在线扩展源漫画：用本地（Page 2 → 远端 No data）成功导出页码', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final EpubBookRow book = await _insertOnlineManga(db);
    await _setLocalPage(db, book, 1);
    final _CloudBackend backend = _CloudBackend();

    final SyncBookResult result = await _sync(
      db,
      backend,
      book,
      SyncDirection.exportToTtu,
    );

    expect(result.error, isNull);
    expect(result.direction, SyncResult.exported);
    expect(classifySyncApply(result), SyncApplyOutcome.applied);
    expect(backend.exported!.exploredCharCount, 1);
    // 在线漫画折算不出全书分数（chapterCount 是章数）：写 0.0，不臆造。
    expect(backend.exported!.progress, 0.0);
  });

  test('在线扩展源漫画：自动方向（无基线、远端无文件）同样导出', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final EpubBookRow book = await _insertOnlineManga(db);
    await _setLocalPage(db, book, 4);
    final _CloudBackend backend = _CloudBackend();

    final SyncBookResult result = await _sync(db, backend, book, null);

    expect(result.error, isNull);
    expect(result.direction, SyncResult.exported);
    expect(backend.exported!.exploredCharCount, 4);
  });

  test('在线扩展源漫画：用远端时页码原样落地', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final EpubBookRow book = await _insertOnlineManga(db);
    await _setLocalPage(db, book, 0, updatedAt: 500);

    final SyncBookResult result = await _sync(
      db,
      _CloudBackend(remotePage: 7),
      book,
      SyncDirection.importFromTtu,
    );

    expect(result.error, isNull);
    expect(result.direction, SyncResult.imported);
    expect((await db.getReaderPosition(book.uid))!.sectionIndex, 7);
  });

  test('syncBook 失败进 app 日志：带书 key、来源类型与阶段', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final EpubBookRow book = await _insertOnlineManga(db);
    await _setLocalPage(db, book, 1);
    final int before = _syncLogEntriesFor(_bookKey).length;

    final SyncBookResult result = await _sync(
      db,
      _CloudBackend(failProgressUpload: true),
      book,
      SyncDirection.exportToTtu,
    );

    expect(result.error, contains('progress upload refused'));
    expect(classifySyncApply(result), SyncApplyOutcome.failed);
    final List<ErrorLogEntry> logged = _syncLogEntriesFor(
      _bookKey,
    ).skip(before).toList();
    expect(logged, hasLength(1));
    expect(logged.single.source, 'SyncManager.syncBook');
    expect(logged.single.error, contains('source=online-manga:mihon'));
    expect(logged.single.error, contains('stage=progress'));
    expect(logged.single.error, contains('progress upload refused'));
    expect(logged.single.stackTrace, isNotNull);
  });

  test('applySyncCompareChoices 把失败原因带回给调用方', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final EpubBookRow book = await _insertOnlineManga(db);
    await _setLocalPage(db, book, 1);
    final _FailingUploadCompareBackend backend = _FailingUploadCompareBackend();
    final List<SyncCompareEntry> entries = await fetchCompareDataForTest(
      db,
      backend,
    );
    final SyncCompareEntry entry = entries.singleWhere(
      (SyncCompareEntry e) => e.title == _title,
    );

    final SyncCompareApplyResult result = await applySyncCompareChoices(
      db: db,
      backend: backend,
      actionable: <SyncCompareEntry>[entry],
      choices: <String, SyncChoice>{_title: SyncChoice.useLocal},
      tempDir: Directory.systemTemp,
    );

    expect(result.applied, 0);
    expect(result.errors, <String>[_title]);
    expect(result.failureReasons[_title], contains('progress upload refused'));
    expect(result.describeFailures(), startsWith('$_title: '));
  });

  group('对比弹窗', () {
    setUp(() => LocaleSettings.setLocale(AppLocale.en));

    testWidgets('「立即同步」失败：弹窗不关，框内显示书名与失败原因', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final EpubBookRow book = await _insertOnlineManga(db);
      await _setLocalPage(db, book, 1);

      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: SyncCompareDialog(
                db: db,
                backend: _FailingUploadCompareBackend(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Finder apply = find.text(t.sync_compare_apply(count: 1));
      expect(apply, findsOneWidget);

      await tester.tap(apply);
      await tester.pumpAndSettle();

      // 弹窗还在（不再「SnackBar 只报书名就关框」），失败原因显示在框里。
      expect(find.byType(SyncCompareDialog), findsOneWidget);
      expect(
        find.textContaining('$_title: ', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('progress upload refused', findRichText: true),
        findsOneWidget,
      );
    });
  });
}
