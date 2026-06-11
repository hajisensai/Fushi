import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_compare_dialog.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki_core/hibiki_core.dart';

HibikiDatabase _memDb() => HibikiDatabase.forTesting(NativeDatabase.memory());

/// One remote book folder. [hasEpub] toggles whether the folder carries a
/// downloadable `.epub` content asset; when false it is an orphan that holds
/// only sync metadata (BUG-049 phantom).
class _OrphanFakeBackend implements SyncBackend {
  _OrphanFakeBackend({required this.hasEpub});
  final bool hasEpub;
  static const String _folderId = 'folder1';

  @override
  Future<String> findOrCreateRootFolder() async => 'root';
  @override
  String? get cachedRootFolderId => null;
  @override
  void restoreCache(
      {String? rootFolderId, Map<String, String>? titleToFolderId}) {}
  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) async =>
      <DriveFile>[DriveFile(id: _folderId, name: 'GhostBook')];
  @override
  void cacheBookFolderIds(List<DriveFile> folders) {}

  @override
  void evictFolderId(String folderId) {}
  @override
  Map<String, String> get cachedFolderIds => const <String, String>{};
  @override
  Future<DriveSyncFiles> listSyncFiles(String f) async =>
      const DriveSyncFiles();
  @override
  Future<List<AssetEntry>> listChildren(String id) async {
    if (id == _folderId && hasEpub) {
      return const <AssetEntry>[AssetEntry(id: 'epub1', name: 'book.epub')];
    }
    // Orphan: only metadata-ish children, no downloadable book.
    return const <AssetEntry>[AssetEntry(id: 'prog1', name: 'progress_x.json')];
  }

  // ── Unreached ─────────────────────────────────────────────────────
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
  Future<String> ensureNamespace(String name) async => name;
  @override
  Future<String> ensureFolder(String parentId, String name) async =>
      throw UnimplementedError();
  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async => null;
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
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      throw UnimplementedError();
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async =>
      throw UnimplementedError();
  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    Uint8List? coverData,
  }) async =>
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
  void clearCache() {}
}

void main() {
  test('metadata-only remote folder is kept but not downloadable (BUG-049)',
      () async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);

    final List<SyncCompareEntry> orphan = await fetchCompareDataForTest(
      db,
      _OrphanFakeBackend(hasEpub: false),
    );
    final ghost = orphan
        .firstWhere((SyncCompareEntry e) => e.title.contains('GhostBook'));
    // Kept (so it can be deleted via the row menu) but never offered as a
    // download that importRemoteBookFolder could never satisfy.
    expect(ghost.remoteFolderId, isNotNull);
    expect(ghost.remoteHasContent, isFalse);
    expect(ghost.isDownloadableRemoteOnly, isFalse);

    final List<SyncCompareEntry> real = await fetchCompareDataForTest(
      db,
      _OrphanFakeBackend(hasEpub: true),
    );
    final book =
        real.firstWhere((SyncCompareEntry e) => e.title.contains('GhostBook'));
    // A remote folder WITH an .epub is still a real downloadable book.
    expect(book.remoteHasContent, isTrue);
    expect(book.isDownloadableRemoteOnly, isTrue);
  });

  test('source guard: _copyWithoutAudio preserves remoteHasContent (BUG-049)',
      () {
    // _copyWithoutAudio rebuilds the entry after a remote-audiobook delete;
    // dropping remoteHasContent would reset it to the default `true` and
    // re-expose the phantom download on a content-less orphan.
    final src =
        File('lib/src/sync/sync_compare_dialog.dart').readAsStringSync();
    final int start = src.indexOf('_copyWithoutAudio(SyncCompareEntry e)');
    expect(start, greaterThanOrEqualTo(0));
    final int end = src.indexOf(');', start);
    final String body = src.substring(start, end);
    expect(body.contains('remoteHasContent: e.remoteHasContent'), isTrue,
        reason: 'rebuilt entry must keep remoteHasContent (BUG-049)');
  });
}
