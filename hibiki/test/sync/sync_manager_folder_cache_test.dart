import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_manager.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki_core/hibiki_core.dart';

HibikiDatabase _testDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// Backend that always fails `findOrCreateRootFolder` with a RETRYABLE error.
/// `syncBook` therefore takes the retry path and gives up — exactly the code
/// path where the on-disk folder cache used to be wiped (the F1 regression).
class _AlwaysRetryableBackend implements SyncBackend {
  int clearCacheCalls = 0;

  @override
  Future<String> findOrCreateRootFolder() async =>
      throw SyncBackendError('transient', isRetryable: true);

  @override
  void clearCache() => clearCacheCalls++;

  @override
  void restoreCache(
      {String? rootFolderId, Map<String, String>? titleToFolderId}) {}

  @override
  String? get cachedRootFolderId => null;

  @override
  Map<String, String> get cachedFolderIds => const <String, String>{};

  // ── Unreached members (findOrCreateRootFolder throws first) ──────────
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
  Future<List<DriveFile>> listBooks(String rootFolderId) async =>
      throw UnimplementedError();
  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    Uint8List? coverData,
  }) async =>
      throw UnimplementedError();
  @override
  Future<DriveSyncFiles> listSyncFiles(String folderId) async =>
      throw UnimplementedError();
  @override
  Future<TtuProgress> getProgressFile(String fileId) async =>
      throw UnimplementedError();
  @override
  Future<List<TtuStatistics>> getStatsFile(String fileId) async =>
      throw UnimplementedError();
  @override
  Future<TtuAudioBook> getAudioBookFile(String fileId) async =>
      throw UnimplementedError();
  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async =>
      throw UnimplementedError();
  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) async =>
      throw UnimplementedError();
  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) async =>
      throw UnimplementedError();
  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) async =>
      throw UnimplementedError();
  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  }) async =>
      throw UnimplementedError();
  @override
  Future<DriveFile?> findContentFile(String folderId, String fileName) async =>
      throw UnimplementedError();
  @override
  void cacheBookFolderIds(List<DriveFile> folders) =>
      throw UnimplementedError();

  // ── SyncAssetStore (unreached: findOrCreateRootFolder throws first) ──
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
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async =>
      throw UnimplementedError();
}

void main() {
  test('retryable error keeps the persisted folder cache (F1 regression)',
      () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);

    // Seed an on-disk folder cache as a prior successful sync would have.
    await repo.setRootFolderId('root-1');
    await repo.setFolderCache(<String, String>{'Book': 'folder-1'});

    await db.insertEpubBook(EpubBooksCompanion.insert(
      title: 'Book',
      epubPath: '/fake/book.epub',
      extractDir: '/fake/extract',
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    final EpubBookRow book = (await db.getAllEpubBooks()).single;

    final backend = _AlwaysRetryableBackend();
    final manager = SyncManager(db: db, backend: backend);

    final SyncBookResult result = await manager.syncBook(
      book: book,
      syncStats: false,
      statsSyncMode: StatisticsSyncMode.merge,
      syncAudioBook: false,
    );

    // The retry path ran (in-memory cache dropped) but gave up...
    expect(backend.clearCacheCalls, greaterThanOrEqualTo(1));
    expect(result.error, isNotNull);

    // ...and the PERSISTED cache must survive a transient failure.
    expect(await repo.getRootFolderId(), 'root-1');
    expect(await repo.getFolderCache(), containsPair('Book', 'folder-1'));
  });
}
