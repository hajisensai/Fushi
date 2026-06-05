import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_manager.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki_core/hibiki_core.dart';

HibikiDatabase _testDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// Minimal in-memory backend driving the three-way decision in SyncManager.
///
/// The only state that matters for these tests is the remote progress file
/// (its name encodes the remote timestamp + fraction) and the in-memory
/// `TtuProgress` payload that an import reads / an export writes. Everything
/// else is a no-op stub so the manager can run the real direction logic.
class _FakeSyncBackend implements SyncBackend {
  _FakeSyncBackend({this.remoteProgressFile, this.remoteProgress});

  /// Remote progress file metadata (name → timestamp/fraction). Null = absent.
  DriveFile? remoteProgressFile;

  /// Remote progress payload returned by `getProgressFile` (import source).
  TtuProgress? remoteProgress;

  /// Captured export write so a test can assert what was pushed.
  TtuProgress? exportedProgress;

  @override
  Future<String> findOrCreateRootFolder() async => 'root';

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    Uint8List? coverData,
  }) async =>
      'folder';

  @override
  Future<DriveSyncFiles> listSyncFiles(String folderId) async =>
      DriveSyncFiles(progress: remoteProgressFile);

  @override
  Future<TtuProgress> getProgressFile(String fileId) async {
    final TtuProgress? progress = remoteProgress;
    if (progress == null) {
      throw StateError('no remote progress payload seeded');
    }
    return progress;
  }

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {
    exportedProgress = progress;
  }

  // ── Cache (real persistence path runs harmlessly) ───────────────────
  String? _cachedRoot;
  final Map<String, String> _cachedFolders = <String, String>{};
  @override
  void clearCache() {
    _cachedRoot = null;
    _cachedFolders.clear();
  }

  @override
  void restoreCache(
      {String? rootFolderId, Map<String, String>? titleToFolderId}) {
    _cachedRoot = rootFolderId;
    if (titleToFolderId != null) _cachedFolders.addAll(titleToFolderId);
  }

  @override
  String? get cachedRootFolderId => _cachedRoot;
  @override
  Map<String, String> get cachedFolderIds => _cachedFolders;
  @override
  void cacheBookFolderIds(List<DriveFile> folders) {}

  // ── Unreached stub members ──────────────────────────────────────────
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async {}
  @override
  Future<bool> get isAuthenticated async => true;
  @override
  Future<String?> get currentEmail async => null;
  @override
  Future<void> authenticate({required SyncRepository repo}) async =>
      throw UnimplementedError();
  @override
  Future<void> signOut({required SyncRepository repo}) async =>
      throw UnimplementedError();
  @override
  Future<bool> restoreAuth(SyncRepository repo) async => true;
  @override
  Future<void> refreshAuth() async {}
  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) async => const [];
  @override
  Future<List<TtuStatistics>> getStatsFile(String fileId) async => const [];
  @override
  Future<TtuAudioBook> getAudioBookFile(String fileId) async =>
      throw UnimplementedError();
  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) async {}
  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) async {}
  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) async {}
  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  }) async {}
  @override
  Future<DriveFile?> findContentFile(String folderId, String fileName) async =>
      null;

  // ── SyncAssetStore (unreached) ──────────────────────────────────────
  @override
  Future<String> ensureNamespace(String name) async =>
      throw UnimplementedError();
  @override
  Future<String> ensureFolder(String parentId, String name) async =>
      throw UnimplementedError();
  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async =>
      throw UnimplementedError();
  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async =>
      throw UnimplementedError();
  @override
  Future<void> putAsset(String namespaceId, String name, File file,
          {void Function(double progress)? onProgress}) async =>
      throw UnimplementedError();
  @override
  Future<void> getAsset(String assetId, File destination,
          {void Function(double progress)? onProgress}) async =>
      throw UnimplementedError();
  @override
  Future<Object?> getJsonAsset(String assetId) async =>
      throw UnimplementedError();
  @override
  Future<void> putJsonAsset(
          String namespaceId, String name, Object? json) async =>
      throw UnimplementedError();
}

/// One chapter of 1000 characters keeps fraction math simple: explored chars
/// map linearly to normCharOffset in 0..10000.
const String _chaptersJson = '[{"characters":1000}]';

DriveFile _progressFile(int timestampMs, double fraction) => DriveFile(
      id: 'progress-id',
      name: progressFileName(timestampMs, fraction),
    );

Future<EpubBookRow> _seedBook(HibikiDatabase db, String title) async {
  await db.insertEpubBook(EpubBooksCompanion.insert(
    bookKey: title,
    title: title,
    epubPath: '/fake/book.epub',
    extractDir: '/fake/extract',
    chapterCount: 1,
    chaptersJson: _chaptersJson,
    importedAt: DateTime.now().millisecondsSinceEpoch,
  ));
  return (await db.getAllEpubBooks()).single;
}

/// Seed a local reader position whose explored-char offset matches [fraction]
/// (single 1000-char chapter), stamped with [updatedAt].
Future<void> _seedPosition(
  HibikiDatabase db,
  String bookKey, {
  required int updatedAt,
  required double fraction,
}) async {
  final int normOffset = (fraction * 10000).round();
  await db.upsertReaderPosition(ReaderPositionsCompanion(
    bookKey: Value(bookKey),
    sectionIndex: const Value(0),
    normCharOffset: Value(normOffset),
    ttuCharOffset: const Value(-1),
    updatedAt: Value(updatedAt),
  ));
}

void main() {
  const String title = 'Conflict Book';
  final String assetKey = sanitizeTtuFilename(title);

  test('both sides diverged from base → conflict, nothing written', () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);

    final EpubBookRow book = await _seedBook(db, title);
    await _seedPosition(db, book.bookKey, updatedAt: 120, fraction: 0.6);
    await db.setSyncBaseline(assetKey, 'progress', 50);

    final backend = _FakeSyncBackend(
      remoteProgressFile: _progressFile(100, 0.4),
      remoteProgress: TtuProgress(
        dataId: 0,
        exploredCharCount: 400,
        progress: 0.4,
        lastBookmarkModified: 100,
      ),
    );
    final manager = SyncManager(db: db, backend: backend);

    final SyncBookResult result = await manager.syncBook(
      book: book,
      syncStats: false,
      statsSyncMode: StatisticsSyncMode.merge,
      syncAudioBook: false,
    );

    expect(result.direction, SyncResult.conflict);
    expect(result.conflictAssetKey, assetKey);
    expect(result.conflictDimension, 'progress');
    expect(result.conflictLocalVersion, 120);
    expect(result.conflictRemoteVersion, 100);

    // No write: local position untouched (still updatedAt 120, normOffset 6000),
    // remote export not called, base untouched.
    final ReaderPositionRow pos = (await db.getReaderPosition(book.bookKey))!;
    expect(pos.updatedAt, 120);
    expect(pos.normCharOffset, 6000);
    expect(backend.exportedProgress, isNull);
    expect(await db.getSyncBaseline(assetKey, 'progress'), 50);
  });

  test('only local diverged → export, base advances to exported ts', () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);

    final EpubBookRow book = await _seedBook(db, title);
    await _seedPosition(db, book.bookKey, updatedAt: 120, fraction: 0.6);
    await db.setSyncBaseline(assetKey, 'progress', 50);

    final backend = _FakeSyncBackend(
      remoteProgressFile: _progressFile(50, 0.3),
      remoteProgress: TtuProgress(
        dataId: 0,
        exploredCharCount: 300,
        progress: 0.3,
        lastBookmarkModified: 50,
      ),
    );
    final manager = SyncManager(db: db, backend: backend);

    final SyncBookResult result = await manager.syncBook(
      book: book,
      syncStats: false,
      statsSyncMode: StatisticsSyncMode.merge,
      syncAudioBook: false,
    );

    expect(result.direction, SyncResult.exported);
    // base == the timestamp written into the remote progress file
    // (= localPosition.updatedAt), which the export also wrote back locally.
    expect(backend.exportedProgress!.lastBookmarkModified, 120);
    expect(await db.getSyncBaseline(assetKey, 'progress'), 120);
  });

  test('only remote diverged → import, base advances to imported ts', () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);

    final EpubBookRow book = await _seedBook(db, title);
    await _seedPosition(db, book.bookKey, updatedAt: 50, fraction: 0.3);
    await db.setSyncBaseline(assetKey, 'progress', 50);

    final backend = _FakeSyncBackend(
      remoteProgressFile: _progressFile(100, 0.6),
      remoteProgress: TtuProgress(
        dataId: 0,
        exploredCharCount: 600,
        progress: 0.6,
        lastBookmarkModified: 100,
      ),
    );
    final manager = SyncManager(db: db, backend: backend);

    final SyncBookResult result = await manager.syncBook(
      book: book,
      syncStats: false,
      statsSyncMode: StatisticsSyncMode.merge,
      syncAudioBook: false,
    );

    expect(result.direction, SyncResult.imported);
    // base == remote progress timestamp, which import also wrote to local updatedAt.
    final ReaderPositionRow pos = (await db.getReaderPosition(book.bookKey))!;
    expect(pos.updatedAt, 100);
    expect(await db.getSyncBaseline(assetKey, 'progress'), 100);
  });
}
