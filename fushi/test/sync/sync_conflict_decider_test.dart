// 同步中途冲突的非交互裁决（`sync_conflict_decider.dart`）：给 [SyncConflictPrompter.present]
// 注入裁决器后不弹窗、按策略用弹窗同一套落地函数写；`ask` 什么都不写、把冲突清单交回；
// 跨通道裁决簿与弹窗同一规则（[seedSyncCompareChoices]）。假后端同 sync_conflict_present_test。
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_compare_dialog.dart';
import 'package:fushi/src/sync/sync_conflict_decider.dart';
import 'package:fushi/src/sync/sync_conflict_prompter.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi_engine/sync/ttu_models.dart';
import 'package:fushi_core/fushi_core.dart';

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// One chapter of 1000 characters keeps fraction math simple.
const String _chaptersJson = '[{"characters":1000}]';

/// Backend test double for the conflict-resolution surface presented by
/// [SyncConflictPrompter.present] → [SyncCompareDialog] (conflictsOnly). Same
/// shape as the compare-dialog test's fake: the `_load` path reads listBooks →
/// listSyncFiles → getProgressFile; members off that path throw.
class _FakeSyncBackend implements SyncBackend {
  _FakeSyncBackend({required this.remoteBooks});

  final Map<String, _RemoteBook> remoteBooks;
  final Map<String, TtuProgress> exportedByFolder = <String, TtuProgress>{};

  @override
  Future<String> findOrCreateRootFolder() async => 'root';
  @override
  Future<List<SyncFileRef>> listBooks(String rootFolderId) async =>
      <SyncFileRef>[
        for (final MapEntry<String, _RemoteBook> e in remoteBooks.entries)
          SyncFileRef(id: e.value.folderId, name: e.key),
      ];
  @override
  void cacheBookFolderIds(List<SyncFileRef> folders) {}

  @override
  void evictFolderId(String folderId) {}
  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async {
    final _RemoteBook? book = _byFolder(folderId);
    if (book == null) return const SyncFileTrio();
    return SyncFileTrio(progress: book.progressFile);
  }

  @override
  Future<TtuProgress> getProgressFile(String fileId) async {
    for (final _RemoteBook b in remoteBooks.values) {
      if (b.progressFile?.id == fileId) return b.payload!;
    }
    throw StateError('no remote progress payload for $fileId');
  }

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {
    exportedByFolder[folderId] = progress;
  }

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) async => remoteBooks[bookTitle]?.folderId ?? 'folder-$bookTitle';

  @override
  Future<String> ensureNamespace(String name) async => name;
  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async =>
      const <AssetEntry>[];

  _RemoteBook? _byFolder(String folderId) {
    for (final _RemoteBook b in remoteBooks.values) {
      if (b.folderId == folderId) return b;
    }
    return null;
  }

  String? _cachedRoot;
  final Map<String, String> _cachedFolders = <String, String>{};
  @override
  void clearCache() {
    _cachedRoot = null;
    _cachedFolders.clear();
  }

  @override
  void restoreCache({
    String? rootFolderId,
    Map<String, String>? titleToFolderId,
  }) {
    _cachedRoot = rootFolderId;
    if (titleToFolderId != null) _cachedFolders.addAll(titleToFolderId);
  }

  @override
  String? get cachedRootFolderId => _cachedRoot;
  @override
  Map<String, String> get cachedFolderIds => _cachedFolders;
  @override
  Future<bool> get isAuthenticated async => true;

  @override
  Future<String?> get currentEmail async => throw UnimplementedError();
  @override
  Future<void> authenticate({required SyncRepository repo}) async =>
      throw UnimplementedError();
  @override
  Future<void> signOut({required SyncRepository repo}) async =>
      throw UnimplementedError();
  @override
  Future<bool> restoreAuth(SyncRepository repo) async =>
      throw UnimplementedError();
  @override
  Future<void> refreshAuth() async => throw UnimplementedError();
  @override
  Future<List<TtuStatistics>> getStatsFile(String fileId) async =>
      throw UnimplementedError();
  @override
  Future<TtuAudioBook> getAudioBookFile(String fileId) async =>
      throw UnimplementedError();
  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) async => throw UnimplementedError();
  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) async => throw UnimplementedError();
  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) async => throw UnimplementedError();
  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  }) async => throw UnimplementedError();
  @override
  Future<SyncFileRef?> findContentFile(
    String folderId,
    String fileName,
  ) async => throw UnimplementedError();
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async =>
      throw UnimplementedError();
  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async =>
      throw UnimplementedError();
  @override
  Future<String> ensureFolder(String parentId, String name) async =>
      throw UnimplementedError();
  @override
  Future<void> putAsset(
    String namespaceId,
    String name,
    File file, {
    void Function(double progress)? onProgress,
  }) async => throw UnimplementedError();
  @override
  Future<void> getAsset(
    String assetId,
    File destination, {
    void Function(double progress)? onProgress,
  }) async => throw UnimplementedError();
  @override
  Future<Object?> getJsonAsset(String assetId) async =>
      throw UnimplementedError();
  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      throw UnimplementedError();
}

class _RemoteBook {
  _RemoteBook({required this.folderId, this.progressFile, this.payload});

  final String folderId;
  final SyncFileRef? progressFile;
  final TtuProgress? payload;

  factory _RemoteBook.withProgress({
    required String folderId,
    required int timestampMs,
    required double fraction,
  }) {
    final int exploredChars = (fraction * 1000).round();
    return _RemoteBook(
      folderId: folderId,
      progressFile: SyncFileRef(
        id: 'progress-$folderId',
        name: progressFileName(timestampMs, fraction),
      ),
      payload: TtuProgress(
        dataId: 0,
        exploredCharCount: exploredChars,
        progress: fraction,
        lastBookmarkModified: timestampMs,
      ),
    );
  }
}

Future<EpubBookRow> _seedBook(FushiDatabase db, String title) async {
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: title,
      title: title,
      epubPath: '/fake/$title.epub',
      extractDir: '/fake/$title',
      chapterCount: 1,
      chaptersJson: _chaptersJson,
      importedAt: DateTime.now().millisecondsSinceEpoch,
    ),
  );
  return (await db.getAllEpubBooks()).firstWhere((b) => b.title == title);
}

Future<void> _seedPosition(
  FushiDatabase db,
  String bookUid, {
  required int updatedAt,
  required double fraction,
}) async {
  final int normOffset = (fraction * 10000).round();
  await db.upsertReaderPosition(
    ReaderPositionsCompanion(
      bookUid: Value(bookUid),
      sectionIndex: const Value(0),
      normCharOffset: Value(normOffset),
      updatedAt: Value(updatedAt),
    ),
  );
}

/// One genuine fork (both sides off baseline) → SyncCompareDialog renders it as
/// a conflict.
List<SyncConflict> _oneConflict() => <SyncConflict>[
  SyncConflict(
    assetKey: sanitizeTtuFilename('BookA'),
    dimension: 'progress',
    title: 'BookA',
    localVersion: 120,
    remoteVersion: 100,
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 分叉的 BookA：基线 50，本机 [localAt]（进度 0.6），对端 [remoteAt]（进度 0.4）。
  Future<(FushiDatabase, _FakeSyncBackend)> seedFork({
    int localAt = 120,
    int remoteAt = 100,
  }) async {
    final FushiDatabase db = _memDb();
    final EpubBookRow book = await _seedBook(db, 'BookA');
    await _seedPosition(db, book.uid, updatedAt: localAt, fraction: 0.6);
    await db.setSyncBaseline(sanitizeTtuFilename('BookA'), 'progress', 50);
    final _FakeSyncBackend fake = _FakeSyncBackend(
      remoteBooks: <String, _RemoteBook>{
        'BookA': _RemoteBook.withProgress(
          folderId: 'folderA',
          timestampMs: remoteAt,
          fraction: 0.4,
        ),
      },
    );
    return (db, fake);
  }

  Future<void> present(
    SyncConflictPrompter prompter,
    FushiDatabase db,
    SyncBackend backend,
    SyncConflictDecider decider, {
    Map<String, SyncChoice>? decisions,
  }) => prompter.present(
    // 没挂到任何界面上：非交互裁决不需要 navigator。
    navigatorKey: GlobalKey<NavigatorState>(),
    db: db,
    backend: backend,
    conflicts: _oneConflict(),
    source: ConflictSource.manual,
    inBook: false,
    decisions: decisions,
    decider: decider,
  );

  test('策略值域：wire 往返', () {
    for (final SyncConflictPolicy p in SyncConflictPolicy.values) {
      expect(SyncConflictPolicy.tryParse(p.wire), p);
    }
    expect(SyncConflictPolicy.tryParse('local'), isNull);
  });

  test('keep-local：不弹窗，把本机这份推过去并记基线与裁决簿', () async {
    final (FushiDatabase db, _FakeSyncBackend fake) = await seedFork();
    addTearDown(db.close);
    final SyncConflictPolicyDecider decider = SyncConflictPolicyDecider(
      SyncConflictPolicy.keepLocal,
      tempDir: Directory.systemTemp,
    );
    final Map<String, SyncChoice> decisions = <String, SyncChoice>{};
    await present(
      SyncConflictPrompter(),
      db,
      fake,
      decider,
      decisions: decisions,
    );
    expect(fake.exportedByFolder['folderA']?.lastBookmarkModified, 120);
    expect(
      await db.getSyncBaseline(sanitizeTtuFilename('BookA'), 'progress'),
      120,
    );
    expect(decider.unresolved, isEmpty);
    expect(decider.resolved.single['title'], 'BookA');
    expect(decider.resolved.single['kept'], 'local');
    expect(decisions[sanitizeTtuFilename('BookA')], SyncChoice.useLocal);
  });

  test('newest：对端更新得更晚 → 采用对端，不推本机', () async {
    final (FushiDatabase db, _FakeSyncBackend fake) = await seedFork(
      localAt: 90,
      remoteAt: 100,
    );
    addTearDown(db.close);
    final SyncConflictPolicyDecider decider = SyncConflictPolicyDecider(
      SyncConflictPolicy.newest,
      tempDir: Directory.systemTemp,
    );
    await present(SyncConflictPrompter(), db, fake, decider);
    expect(fake.exportedByFolder, isEmpty);
    expect(decider.resolved.single['kept'], 'remote');
    expect(decider.unresolved, isEmpty);
  });

  test('ask：什么都不写，冲突清单交回，也不进会话静默', () async {
    final (FushiDatabase db, _FakeSyncBackend fake) = await seedFork();
    addTearDown(db.close);
    final SyncConflictPrompter prompter = SyncConflictPrompter();
    final SyncConflictPolicyDecider decider = SyncConflictPolicyDecider(
      SyncConflictPolicy.ask,
    );
    await present(prompter, db, fake, decider);
    expect(fake.exportedByFolder, isEmpty);
    expect(decider.resolved, isEmpty);
    final Map<String, Object?> row = decider.unresolved.single;
    expect(row['type'], 'book');
    expect(row['title'], 'BookA');
    expect(row['localUpdatedAt'], 120);
    expect(row['remoteUpdatedAt'], 100);
    expect(decider.toJson()['policy'], 'ask');
    expect(prompter.dialogOpen, isFalse);
    expect(
      prompter.shouldPrompt(
        conflicts: _oneConflict(),
        source: ConflictSource.auto,
        inBook: false,
      ),
      isTrue,
      reason: '没裁决的冲突留给之后的同步照常弹',
    );
  });

  test('裁决簿上已有的书按簿落地（与弹窗同一规则），不再套策略', () async {
    final (FushiDatabase db, _FakeSyncBackend fake) = await seedFork();
    addTearDown(db.close);
    final SyncConflictPolicyDecider decider = SyncConflictPolicyDecider(
      SyncConflictPolicy.ask,
      tempDir: Directory.systemTemp,
    );
    await present(
      SyncConflictPrompter(),
      db,
      fake,
      decider,
      decisions: <String, SyncChoice>{
        sanitizeTtuFilename('BookA'): SyncChoice.useLocal,
      },
    );
    expect(fake.exportedByFolder['folderA']?.lastBookmarkModified, 120);
    expect(decider.resolved.single['kept'], 'local');
    expect(decider.unresolved, isEmpty);
  });

  test('seedSyncCompareChoices：簿上「用远端」而本通道又分叉 → 仍待裁决', () async {
    final (FushiDatabase db, _FakeSyncBackend fake) = await seedFork();
    addTearDown(db.close);
    final List<SyncCompareEntry> books = (await loadSyncCompareData(
      db,
      fake,
    )).books;
    final String key = sanitizeTtuFilename('BookA');
    expect(seedSyncCompareChoices(books, null).undecided, <String>{'BookA'});
    expect(
      seedSyncCompareChoices(books, <String, SyncChoice>{
        key: SyncChoice.useRemote,
      }).undecided,
      <String>{'BookA'},
    );
    final ({Map<String, SyncChoice> choices, Set<String> undecided}) skip =
        seedSyncCompareChoices(books, <String, SyncChoice>{
          key: SyncChoice.skip,
        });
    expect(skip.undecided, isEmpty);
    expect(skip.choices['BookA'], SyncChoice.skip);
  });
}
