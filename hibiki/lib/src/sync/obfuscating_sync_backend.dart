import 'dart:io';
import 'dart:typed_data';

import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_obfuscator.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_models.dart';

/// 「防扫盘」字节混淆装饰器（TODO-623 A1）。
///
/// 包裹一个真实云后端 [_inner]，对内容字节 + 封面字节两侧插入 [SyncObfuscator]
/// 的固定密钥 XOR 混淆，让云盘网页端 / 文件管理器扫盘看不到明文 epub / 封面 / 音频 /
/// 词典内容。文件名、文件夹结构、JSON 元数据全部原样委托（不混淆），所以同步协议
/// （对比 / 增量 / 冲突 / 删除全靠文件名）零影响。
///
/// 混淆插入点（只有这 5 个数据入口，其余方法纯委托）：
/// - [uploadContentFile] / [putAsset]：上传前把本地文件流式混淆到临时文件再传。
/// - [downloadContentFile] / [getAsset]：inner 先落临时，再流式反混淆到目标。
/// - [ensureBookFolder] 的 coverData：整块混淆（封面是小数据）。
///
/// A2（JSON 正文混淆）是 follow-up：本装饰器不碰 [updateProgressFile] /
/// [getProgressFile] / [getJsonAsset] / [putJsonAsset] 等 JSON 方法（A2 会破坏
/// 第三方 ッツ 互通，待用户答复）——它们全部纯委托。
///
/// 向后兼容：[SyncObfuscator] 用 magic header 做混读判定，现有 Drive 明文（无魔数）
/// 下载时原样落地仍可导入；新上传带魔数混淆，逐步重传即全部变混淆，无需一键全重传。
class ObfuscatingSyncBackend extends SyncBackend {
  ObfuscatingSyncBackend(this._inner);

  final SyncBackend _inner;

  /// 暴露被包裹的真后端（测试 / 诊断用）。
  SyncBackend get inner => _inner;

  // ── 混淆临时文件辅助 ──────────────────────────────────────────────

  /// 把 [source] 文件经 [SyncObfuscator.obfuscateStream] 写到一个临时文件，
  /// 返回该临时文件；调用方用完须删。流式，不把大文件读进内存。
  Future<File> _obfuscateToTemp(File source) async {
    final tmp = await _createTempFile('obf_up_');
    final sink = tmp.openWrite();
    try {
      await sink.addStream(SyncObfuscator.obfuscateStream(source.openRead()));
    } finally {
      await sink.close();
    }
    return tmp;
  }

  /// 把 [obfuscated] 文件经 [SyncObfuscator.deobfuscateStream] 还原到 [destination]
  /// （混读：无魔数的旧明文原样透传）。流式，不把大文件读进内存。
  Future<void> _deobfuscateToDestination(
      File obfuscated, File destination) async {
    await destination.parent.create(recursive: true);
    final sink = destination.openWrite();
    try {
      await sink
          .addStream(SyncObfuscator.deobfuscateStream(obfuscated.openRead()));
    } finally {
      await sink.close();
    }
  }

  Future<File> _createTempFile(String prefix) async {
    final dir = await Directory.systemTemp.createTemp(prefix);
    return File('${dir.path}/blob');
  }

  Future<void> _deleteTemp(File tmp) async {
    try {
      final parent = tmp.parent;
      if (await tmp.exists()) await tmp.delete();
      if (await parent.exists()) await parent.delete(recursive: true);
    } catch (_) {
      // 临时文件清理失败不影响同步结果；系统临时目录会被 OS 回收。
    }
  }

  // ── Auth（纯委托） ────────────────────────────────────────────────

  @override
  Future<bool> get isAuthenticated => _inner.isAuthenticated;

  @override
  Future<String?> get currentEmail => _inner.currentEmail;

  @override
  Future<void> authenticate({required SyncRepository repo}) =>
      _inner.authenticate(repo: repo);

  @override
  Future<void> signOut({required SyncRepository repo}) =>
      _inner.signOut(repo: repo);

  @override
  Future<bool> restoreAuth(SyncRepository repo) => _inner.restoreAuth(repo);

  @override
  Future<void> refreshAuth() => _inner.refreshAuth();

  // ── Folder operations ────────────────────────────────────────────

  @override
  Future<String> findOrCreateRootFolder() => _inner.findOrCreateRootFolder();

  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) =>
      _inner.listBooks(rootFolderId);

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    Uint8List? coverData,
  }) =>
      _inner.ensureBookFolder(
        bookTitle: bookTitle,
        rootFolderId: rootFolderId,
        // 封面是小数据，整块混淆。null 原样透传。
        coverData:
            coverData == null ? null : SyncObfuscator.obfuscateBytes(coverData),
      );

  // ── Metadata sync (JSON, 纯委托 — A2 follow-up) ───────────────────

  @override
  Future<DriveSyncFiles> listSyncFiles(String folderId) =>
      _inner.listSyncFiles(folderId);

  @override
  Future<TtuProgress> getProgressFile(String fileId) =>
      _inner.getProgressFile(fileId);

  @override
  Future<List<TtuStatistics>> getStatsFile(String fileId) =>
      _inner.getStatsFile(fileId);

  @override
  Future<TtuAudioBook> getAudioBookFile(String fileId) =>
      _inner.getAudioBookFile(fileId);

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) =>
      _inner.updateProgressFile(
          folderId: folderId, fileId: fileId, progress: progress);

  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) =>
      _inner.updateStatsFile(folderId: folderId, fileId: fileId, stats: stats);

  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) =>
      _inner.updateAudioBookFile(
          folderId: folderId, fileId: fileId, audioBook: audioBook);

  // ── Content file sync（混淆插入点） ───────────────────────────────

  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) async {
    final tmp = await _obfuscateToTemp(file);
    try {
      await _inner.uploadContentFile(
        folderId: folderId,
        fileName: fileName,
        file: tmp,
        onProgress: onProgress,
      );
    } finally {
      await _deleteTemp(tmp);
    }
  }

  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  }) async {
    final tmp = await _createTempFile('obf_dn_');
    try {
      await _inner.downloadContentFile(
        fileId: fileId,
        destination: tmp,
        onProgress: onProgress,
      );
      await _deobfuscateToDestination(tmp, destination);
    } finally {
      await _deleteTemp(tmp);
    }
  }

  @override
  Future<DriveFile?> findContentFile(String folderId, String fileName) =>
      _inner.findContentFile(folderId, fileName);

  // ── Cache（纯委托） ───────────────────────────────────────────────

  @override
  void clearCache() => _inner.clearCache();

  @override
  void restoreCache({
    String? rootFolderId,
    Map<String, String>? titleToFolderId,
  }) =>
      _inner.restoreCache(
          rootFolderId: rootFolderId, titleToFolderId: titleToFolderId);

  @override
  String? get cachedRootFolderId => _inner.cachedRootFolderId;

  @override
  Map<String, String> get cachedFolderIds => _inner.cachedFolderIds;

  @override
  void cacheBookFolderIds(List<DriveFile> folders) =>
      _inner.cacheBookFolderIds(folders);

  @override
  void evictFolderId(String folderId) => _inner.evictFolderId(folderId);

  // ── SyncAssetStore ────────────────────────────────────────────────

  @override
  Future<String> ensureNamespace(String name) => _inner.ensureNamespace(name);

  @override
  Future<String> ensureFolder(String parentId, String name) =>
      _inner.ensureFolder(parentId, name);

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) =>
      _inner.listChildren(namespaceId);

  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) =>
      _inner.findAsset(namespaceId, name);

  @override
  Future<void> putAsset(
    String namespaceId,
    String name,
    File file, {
    void Function(double progress)? onProgress,
  }) async {
    final tmp = await _obfuscateToTemp(file);
    try {
      await _inner.putAsset(namespaceId, name, tmp, onProgress: onProgress);
    } finally {
      await _deleteTemp(tmp);
    }
  }

  @override
  Future<void> getAsset(
    String assetId,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    final tmp = await _createTempFile('obf_get_');
    try {
      await _inner.getAsset(assetId, tmp, onProgress: onProgress);
      await _deobfuscateToDestination(tmp, destination);
    } finally {
      await _deleteTemp(tmp);
    }
  }

  // getJsonAsset / putJsonAsset 纯委托（A2 follow-up，不混淆 JSON）。
  @override
  Future<Object?> getJsonAsset(String assetId) => _inner.getJsonAsset(assetId);

  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      _inner.putJsonAsset(namespaceId, name, json);

  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) =>
      _inner.deleteAsset(id, isFolder: isFolder);
}
