import 'dart:io';
import 'dart:typed_data';

import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_models.dart';

import '../fake_asset_store.dart';

/// 共享测试夹具：orchestrator live 测试的「云路径」backend 双替身。它把 SyncAssetStore
/// 面的调用全部委托给注入的 [FakeAssetStore]，而 drive/ttu 面（进度/统计/有声书/内容
/// 文件）保持空/抛错存根——orchestrator 在 syncContent / syncLocalAudio / syncAudioBookFiles
/// 关闭的用例里绝不该走到那些方法。
///
/// sync_orchestrator_live_book / sync_orchestrator_live_audio 此前各自复制同一套实现，
/// 仅在「插桩计数器」上有细微差异（book 记 [ensureBookFolderCalled]，audio 记
/// [ensureNamespaceCalled]）。此处把两个计数器都并进来：各测试只断言自己关心的那个，
/// 另一个静默维护、互不干扰，故两份测试语义逐字保留。
class StagedAssetStoreSyncBackend implements SyncBackend {
  StagedAssetStoreSyncBackend(this._store);
  final FakeAssetStore _store;

  /// book 用例：`ensureBookFolder` 是否被调用过。
  bool ensureBookFolderCalled = false;

  /// audio 用例：`ensureNamespace` 被调用次数。
  int ensureNamespaceCalled = 0;

  @override
  Future<String> ensureNamespace(String name) {
    ensureNamespaceCalled++;
    return _store.ensureNamespace(name);
  }

  @override
  Future<String> ensureFolder(String parentId, String name) =>
      _store.ensureFolder(parentId, name);
  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) =>
      _store.listChildren(namespaceId);
  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) =>
      _store.findAsset(namespaceId, name);
  @override
  Future<void> putAsset(String namespaceId, String name, File file,
          {void Function(double progress)? onProgress}) =>
      _store.putAsset(namespaceId, name, file, onProgress: onProgress);
  @override
  Future<void> getAsset(String assetId, File destination,
          {void Function(double progress)? onProgress}) =>
      _store.getAsset(assetId, destination, onProgress: onProgress);
  @override
  Future<Object?> getJsonAsset(String assetId) => _store.getJsonAsset(assetId);
  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      _store.putJsonAsset(namespaceId, name, json);
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) =>
      _store.deleteAsset(id, isFolder: isFolder);
  @override
  Future<String> findOrCreateRootFolder() async => 'root';
  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    Uint8List? coverData,
  }) {
    ensureBookFolderCalled = true;
    return _store.ensureFolder(rootFolderId, bookTitle);
  }

  @override
  Future<DriveSyncFiles> listSyncFiles(String folderId) async =>
      const DriveSyncFiles(progress: null, statistics: null, audioBook: null);
  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) async =>
      const <DriveFile>[];
  @override
  Future<bool> get isAuthenticated async => true;
  @override
  Future<String?> get currentEmail async => null;
  @override
  Future<void> authenticate({required SyncRepository repo}) async {}
  @override
  Future<void> signOut({required SyncRepository repo}) async {}
  @override
  Future<bool> restoreAuth(SyncRepository repo) async => true;
  @override
  Future<void> refreshAuth() async {}
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
  }) async {}
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
  @override
  void clearCache() {}
  @override
  void restoreCache(
      {String? rootFolderId, Map<String, String>? titleToFolderId}) {}
  @override
  String? get cachedRootFolderId => 'root';
  @override
  Map<String, String> get cachedFolderIds => const <String, String>{};
  @override
  void cacheBookFolderIds(List<DriveFile> folders) {}

  @override
  void evictFolderId(String folderId) {}
}
