import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_obfuscator.dart';
import 'package:fushi/src/sync/sync_remote_listing.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/sync/ttu_models.dart';

/// 「防扫盘」字节混淆装饰器（TODO-623 A1）。
///
/// 包裹一个真实云后端 [_inner]，对内容字节 + 封面字节两侧插入 [SyncObfuscator]
/// 的固定密钥 XOR 混淆，让云盘网页端 / 文件管理器扫盘看不到明文 epub / 封面 / 音频 /
/// 词典内容。文件名、文件夹结构、JSON 元数据全部原样委托（不混淆），所以同步协议
/// （对比 / 增量 / 冲突 / 删除全靠文件名）零影响。
///
/// 混淆插入点（只有这 5 个数据入口，其余方法纯委托）：
/// - [uploadContentFile] / [putAsset]：上传前把本地文件混淆到临时文件再传（Rust 整段读写）。
/// - [downloadContentFile] / [getAsset]：inner 先落临时，再还原到目标（Rust 整段读写）。
/// - [ensureBookFolder] 的 coverData：整块混淆（封面是小数据）。
///
/// A2（JSON 正文混淆）是 follow-up：本装饰器不碰 [updateProgressFile] /
/// [getProgressFile] / [getJsonAsset] / [putJsonAsset] 等 JSON 方法（A2 会破坏
/// 第三方 ッツ 互通，待用户答复）——它们全部纯委托。
///
/// 向后兼容：[SyncObfuscator] 用 magic header 做混读判定，现有 Drive 明文（无魔数）
/// 下载时原样落地仍可导入；新上传带魔数混淆，逐步重传即全部变混淆，无需一键全重传。
class ObfuscatingSyncBackend extends SyncBackend
    implements RemoteListingCapable {
  /// [tempRoot] 仅供测试注入：给了就把临时目录建在它下面，并且不触发进程级的
  /// [sweepStaleTemps]（测试不去动真实系统临时目录）。
  ObfuscatingSyncBackend(this._inner, {Directory? tempRoot})
    : _tempRoot = tempRoot;

  final SyncBackend _inner;
  final Directory? _tempRoot;

  /// 暴露被包裹的真后端（测试 / 诊断用）。
  SyncBackend get inner => _inner;

  // ── 混淆临时文件的归属与启动清理（BUG-4227） ─────────────────────────
  //
  // 上传 / 下载的混淆临时文件与原文件同尺寸（有声书可达数百 MB）。try/finally 只能
  // 覆盖进程活着时的异常路径；iOS 在上传途中挂起 / 内存压力杀进程时 finally 根本
  // 不会执行，临时目录就永久留在 tmp/ 里。所以生命周期分两层兜住：
  // 1. 进程内：建临时目录后立刻进 try/finally（含混淆本身失败）。
  // 2. 跨进程：所有临时目录只建在本功能独占的 [tempDirName] 子目录下，每个进程第一次
  //    用临时目录之前（以及启动时）整目录清掉上一个进程的遗留；同一进程内的清理与
  //    新建经同一个 memo Future 排序，绝不会删到本进程正在用的临时目录。

  /// 本功能独占的临时子目录名（位于 [Directory.systemTemp] 下）。
  static const String tempDirName = 'fushi_sync_obf';

  /// 旧版本直接建在 [Directory.systemTemp] 根下的临时目录名形态（`createTemp` 前缀 +
  /// 随机后缀）。只用于识别遗留目录。
  static final RegExp _legacyTempDirName = RegExp(r'^obf_(up|dn|get)_[^/\\]+$');

  /// 旧版本每个临时目录里只会有这一个文件。
  static const String _blobName = 'blob';

  static Future<int>? _sweepOnce;

  /// 进程级一次性清理上一个进程遗留的混淆临时目录（启动时调用；临时目录创建前也会
  /// 先等它完成）。返回删掉的目录数。
  ///
  /// 清理失败记进错误日志后返回 0：删不掉旧遗留不应让本进程的同步全部失败（memo
  /// 住一个失败 Future 会让之后每次建临时目录都抛）。
  static Future<int> sweepStaleTemps() =>
      _sweepOnce ??= sweepStaleTempsIn(Directory.systemTemp).then(
        (int removed) => removed,
        onError: (Object e, StackTrace st) {
          ErrorLogService.instance.log(
            'ObfuscatingSyncBackend.sweepStaleTemps',
            e,
            st,
          );
          return 0;
        },
      );

  /// 清理 [systemTemp] 下本功能遗留的临时目录：
  /// - 整个 [tempDirName] 子目录（本功能独占）；
  /// - 旧版本建在根下的 `obf_up_*` / `obf_dn_*` / `obf_get_*`，且目录里只有 `blob`
  ///   一个文件（或为空）——名字与内容双重指纹都对上才删，桌面端共享的系统临时目录里
  ///   别的程序的同名前缀目录不会被误删。
  ///
  /// 不吞异常：删除失败照常抛给调用方（启动处记日志）。
  static Future<int> sweepStaleTempsIn(Directory systemTemp) async {
    if (!await systemTemp.exists()) return 0;
    int removed = 0;
    final Directory owned = Directory('${systemTemp.path}/$tempDirName');
    if (await owned.exists()) {
      await owned.delete(recursive: true);
      removed++;
    }
    final List<Directory> legacy = <Directory>[];
    await for (final FileSystemEntity e in systemTemp.list(
      followLinks: false,
    )) {
      if (e is! Directory) continue;
      if (!_legacyTempDirName.hasMatch(_baseName(e))) continue;
      if (await _isLegacyTempDir(e)) legacy.add(e);
    }
    for (final Directory d in legacy) {
      await d.delete(recursive: true);
      removed++;
    }
    return removed;
  }

  static String _baseName(FileSystemEntity e) {
    final List<String> parts = e.path.split(RegExp(r'[/\\]'));
    return parts.lastWhere((String s) => s.isNotEmpty, orElse: () => '');
  }

  static Future<bool> _isLegacyTempDir(Directory dir) async {
    await for (final FileSystemEntity e in dir.list(followLinks: false)) {
      if (e is! File || _baseName(e) != _blobName) return false;
    }
    return true;
  }

  // ── 混淆临时文件辅助 ──────────────────────────────────────────────

  /// 把 [source] 混淆到一个临时文件后交给 [body] 使用；无论混淆本身还是 [body] 失败，
  /// 临时目录都在 finally 里删掉。整段在 Rust 里流式读写，不把大文件读进内存。
  Future<void> _withObfuscatedTemp(
    File source,
    Future<void> Function(File obfuscated) body,
  ) async {
    final File tmp = await _createTempFile('obf_up_');
    try {
      await SyncObfuscator.obfuscateFile(source, tmp);
      await body(tmp);
    } finally {
      await _deleteTemp(tmp);
    }
  }

  /// 把 [obfuscated] 文件经 [SyncObfuscator.deobfuscateFile] 还原到 [destination]
  /// （混读：无魔数的旧明文原样复制）。整段在 Rust 里流式读写。
  Future<void> _deobfuscateToDestination(
    File obfuscated,
    File destination,
  ) async {
    await destination.parent.create(recursive: true);
    await SyncObfuscator.deobfuscateFile(obfuscated, destination);
  }

  Future<File> _createTempFile(String prefix) async {
    final Directory? injected = _tempRoot;
    final Directory root;
    if (injected != null) {
      root = injected;
    } else {
      // 先等进程级清理跑完，再在独占子目录下建，保证清理不会删到本进程的新临时目录。
      await sweepStaleTemps();
      root = Directory('${Directory.systemTemp.path}/$tempDirName');
    }
    await root.create(recursive: true);
    final Directory dir = await root.createTemp(prefix);
    return File('${dir.path}/$_blobName');
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
  Future<List<SyncFileRef>> listBooks(String rootFolderId) =>
      _inner.listBooks(rootFolderId);

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) => _inner.ensureBookFolder(
    bookTitle: bookTitle,
    rootFolderId: rootFolderId,
    // 封面是小数据，整块混淆。null 原样透传。混淆包在惰性回调「里面」，
    // 所以内层后端缓存命中不调用回调时，既不读磁盘也不做混淆（TODO-2657）。
    readCoverData: readCoverData == null
        ? null
        : _obfuscateCover(readCoverData),
  );

  /// 把惰性封面来源 [inner] 包一层混淆，保持惰性（只在被调用时才读+混淆）。
  static SyncCoverDataProvider _obfuscateCover(SyncCoverDataProvider inner) =>
      () async {
        final Uint8List? data = await inner();
        return data == null ? null : SyncObfuscator.obfuscateBytes(data);
      };

  // ── Metadata sync (JSON, 纯委托 — A2 follow-up) ───────────────────

  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) =>
      _inner.listSyncFiles(folderId);

  // 快照只含文件名与定位符，不含任何内容字节，故与混淆层无关：能力随内层有无而定，
  // 内层不支持就同样报告不支持（返回 null），绝不假装自己能一次列举。
  @override
  Future<RemoteListingSnapshot?> snapshotListing(String rootFolderId) {
    final SyncBackend inner = _inner;
    if (inner is! RemoteListingCapable) {
      return Future<RemoteListingSnapshot?>.value();
    }
    return (inner as RemoteListingCapable).snapshotListing(rootFolderId);
  }

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
  }) => _inner.updateProgressFile(
    folderId: folderId,
    fileId: fileId,
    progress: progress,
  );

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
  }) => _inner.updateAudioBookFile(
    folderId: folderId,
    fileId: fileId,
    audioBook: audioBook,
  );

  // ── Content file sync（混淆插入点） ───────────────────────────────

  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    SyncTransferProgress? onProgress,
  }) async {
    await _withObfuscatedTemp(
      file,
      (File tmp) => _inner.uploadContentFile(
        folderId: folderId,
        fileName: fileName,
        file: tmp,
        onProgress: onProgress,
      ),
    );
  }

  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    SyncTransferProgress? onProgress,
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
  Future<SyncFileRef?> findContentFile(String folderId, String fileName) =>
      _inner.findContentFile(folderId, fileName);

  // ── Cache（纯委托） ───────────────────────────────────────────────

  @override
  void clearCache() => _inner.clearCache();

  @override
  void restoreCache({
    String? rootFolderId,
    Map<String, String>? titleToFolderId,
  }) => _inner.restoreCache(
    rootFolderId: rootFolderId,
    titleToFolderId: titleToFolderId,
  );

  @override
  String? get cachedRootFolderId => _inner.cachedRootFolderId;

  @override
  Map<String, String> get cachedFolderIds => _inner.cachedFolderIds;

  @override
  void cacheBookFolderIds(List<SyncFileRef> folders) =>
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
    SyncTransferProgress? onProgress,
  }) async {
    await _withObfuscatedTemp(
      file,
      (File tmp) =>
          _inner.putAsset(namespaceId, name, tmp, onProgress: onProgress),
    );
  }

  @override
  Future<void> getAsset(
    String assetId,
    File destination, {
    SyncTransferProgress? onProgress,
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
