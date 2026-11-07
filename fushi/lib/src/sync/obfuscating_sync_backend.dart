import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_obfuscator.dart';
import 'package:fushi/src/sync/sync_remote_listing.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/sync/ttu_models.dart';
import 'package:path/path.dart' as p;

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
  /// [tempRoot] 仅供测试注入：替代 [defaultTempRoot] 作为临时根（槽位认领 / 死槽位
  /// 清理照常在它下面进行），测试不碰真实的 app 缓存目录。
  ObfuscatingSyncBackend(this._inner, {Directory? tempRoot})
    : _tempRoot = tempRoot;

  final SyncBackend _inner;
  final Directory? _tempRoot;

  /// 暴露被包裹的真后端（测试 / 诊断用）。
  SyncBackend get inner => _inner;

  // ── 混淆临时文件的归属与清理（BUG-4227） ─────────────────────────
  //
  // 上传 / 下载的混淆临时文件与原文件同尺寸（有声书可达数百 MB）。try/finally 只能
  // 覆盖进程活着时的异常路径；iOS 在上传途中挂起 / 内存压力杀进程时 finally 根本
  // 不会执行。所以生命周期分两层兜住：
  // 1. 进程内：建临时目录后立刻进 try/finally（含混淆本身失败）。
  // 2. 跨进程：每个进程在独占根下认领一个「槽位」目录并一直持有它的独占文件锁；
  //    认领时（注册锁内）删掉锁拿得到的兄弟槽位——所有者已死，锁随进程退出被 OS
  //    释放——活进程的槽位锁拿不到，绝不删。
  //
  // 布局（根默认在本用户、本 app 私有的缓存目录下，不在多用户共享的 /tmp）：
  //   <appCache>/fushi_sync_obf/
  //     .registry.lock          认领槽位 + 清理死槽位时的跨进程互斥
  //     p_<pid>_<rand>/         每个进程一个槽位
  //       .owner.lock           所有者进程存活期间一直持有独占锁
  //       obf_up_<rand>/blob    单次上传 / 下载的临时目录

  /// 本功能独占的临时根目录名（位于 app 私有缓存目录下）。
  static const String tempDirName = 'fushi_sync_obf';

  static const String _registryLockName = '.registry.lock';
  static const String _ownerLockName = '.owner.lock';
  static const String _slotPrefix = 'p_';
  static final RegExp _slotName = RegExp(r'^p_(\d+)_');

  /// 旧版本直接建在 [Directory.systemTemp] 根下的临时目录名形态（`createTemp` 前缀 +
  /// 随机后缀）。只用于识别遗留目录。
  static final RegExp _legacyTempDirName = RegExp(r'^obf_(up|dn|get)_[^/\\]+$');

  /// 每个临时目录里只会有这一个文件。
  static const String _blobName = 'blob';

  /// 根目录绝对路径 → 本进程（本 isolate）在该根下认领的槽位。
  static final Map<String, Future<_TempSlot>> _slots =
      <String, Future<_TempSlot>>{};

  static Future<int>? _legacySweepOnce;

  /// 生产环境的临时根：`<getApplicationCacheDirectory()>/fushi_sync_obf`。
  ///
  /// 不用 [Directory.systemTemp]：Linux 上它常是多用户共享的 `/tmp`，固定名字的
  /// 子目录会被先建它的用户占住（别的用户在里面 createTemp 报 EACCES），也能被别的
  /// 本地用户抢先建成 0777 来读 / 换混淆中间文件。app 缓存目录各平台都是本用户、
  /// 本 app 私有（iOS / Android 是沙盒，桌面是 XDG_CACHE_HOME / LocalAppData /
  /// ~/Library/Caches/<bundle id>）。
  static Future<Directory> defaultTempRoot() async => Directory(
    p.join((await AppPaths.appCacheRootDirectory()).path, tempDirName),
  );

  /// 启动时调用：在默认根下认领本进程槽位（顺带删掉已死进程的槽位），并清理旧版本
  /// 散落在 [Directory.systemTemp] 根下的 `obf_*`。返回删掉的目录数。
  ///
  /// 失败记进错误日志后返回已删数：启动清理是 fire-and-forget；认领失败不 memo，
  /// 之后第一次建临时目录会重新认领，错误照常抛给那次同步。
  static Future<int> sweepStaleTemps() async {
    int removed = 0;
    try {
      removed += (await _claimSlot(await defaultTempRoot())).sweptDead;
    } catch (e, st) {
      ErrorLogService.instance.log('ObfuscatingSyncBackend.claimSlot', e, st);
    }
    removed += await (_legacySweepOnce ??=
        sweepLegacyTempsIn(Directory.systemTemp).then(
          (int n) => n,
          onError: (Object e, StackTrace st) {
            ErrorLogService.instance.log(
              'ObfuscatingSyncBackend.sweepLegacyTemps',
              e,
              st,
            );
            return 0;
          },
        ));
    return removed;
  }

  /// 清理旧版本建在 [systemTemp] 根下的 `obf_up_*` / `obf_dn_*` / `obf_get_*`：
  /// 名字匹配且目录里只有 `blob` 一个文件（或为空）才删——桌面端共享的系统临时目录
  /// 里别的程序的同前缀目录不会被误删。只碰根下这些遗留，不碰任何子目录。
  ///
  /// 不吞异常：删除失败照常抛给调用方（启动处记日志）。
  static Future<int> sweepLegacyTempsIn(Directory systemTemp) async {
    if (!await systemTemp.exists()) return 0;
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
    }
    return legacy.length;
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

  /// 本进程在 [root] 下的槽位（memo）。认领失败不 memo，下次重新认领。
  static Future<_TempSlot> _claimSlot(Directory root) {
    final String key = root.absolute.path;
    final Future<_TempSlot>? existing = _slots[key];
    if (existing != null) return existing;
    final Future<_TempSlot> claimed = _doClaimSlot(root);
    _slots[key] = claimed;
    claimed.then(
      (_TempSlot _) {},
      onError: (Object _) {
        if (identical(_slots[key], claimed)) _slots.remove(key);
      },
    );
    return claimed;
  }

  static Future<_TempSlot> _doClaimSlot(Directory root) async {
    await root.create(recursive: true);
    final RandomAccessFile registry = await File(
      p.join(root.path, _registryLockName),
    ).open(mode: FileMode.append);
    try {
      await registry.lock(FileLock.blockingExclusive);
      try {
        final int swept = await _sweepDeadSlots(root);
        final Directory dir = await root.createTemp('$_slotPrefix${pid}_');
        final RandomAccessFile owner = await File(
          p.join(dir.path, _ownerLockName),
        ).open(mode: FileMode.append);
        try {
          await owner.lock(FileLock.exclusive);
        } catch (_) {
          await owner.close();
          rethrow;
        }
        // owner 句柄在进程存活期间一直不关：锁随进程退出才由 OS 释放。
        return _TempSlot(dir, owner, swept);
      } finally {
        await registry.unlock();
      }
    } finally {
      await registry.close();
    }
  }

  /// 删 [root] 下所有者已死的槽位（调用方持有注册锁）。返回删掉的槽位数。
  ///
  /// 跳过名字里 pid 等于本进程的槽位：POSIX 的 fcntl 记录锁对同一进程不互斥，同进程
  /// 另一个 isolate 的活槽位在这里也能「拿到锁」，且关句柄会连带释放它的锁，所以同
  /// pid 一律当活的。
  static Future<int> _sweepDeadSlots(Directory root) async {
    final List<Directory> dead = <Directory>[];
    await for (final FileSystemEntity e in root.list(followLinks: false)) {
      if (e is! Directory) continue;
      final RegExpMatch? m = _slotName.firstMatch(_baseName(e));
      if (m == null) continue;
      if (int.parse(m.group(1)!) == pid) continue;
      if (await _isSlotOwnerDead(e)) dead.add(e);
    }
    int removed = 0;
    for (final Directory d in dead) {
      try {
        await d.delete(recursive: true);
        removed++;
      } on FileSystemException catch (e, st) {
        // 删不掉一个死槽位（如被外部占用）不该让本进程认领失败、同步全挂；记日志，
        // 下个进程认领时再删。
        ErrorLogService.instance.log(
          'ObfuscatingSyncBackend.sweepDeadSlots',
          e,
          st,
        );
      }
    }
    return removed;
  }

  /// 槽位所有者是否已死：锁文件不存在（认领在注册锁内完成，活进程的槽位此刻必有
  /// 锁文件，没有说明进程死在认领途中）或能拿到它的独占锁。
  static Future<bool> _isSlotOwnerDead(Directory slot) async {
    final File lockFile = File(p.join(slot.path, _ownerLockName));
    if (!await lockFile.exists()) return true;
    final RandomAccessFile raf = await lockFile.open(mode: FileMode.append);
    try {
      try {
        await raf.lock(FileLock.exclusive);
      } on FileSystemException {
        return false; // 别的活进程持有锁。
      }
      await raf.unlock();
      return true;
    } finally {
      await raf.close();
    }
  }

  /// 测试用：关掉本进程所有槽位的锁句柄并清空 memo（Windows 上句柄不关删不掉目录）。
  @visibleForTesting
  static Future<void> debugReleaseSlots() async {
    final List<Future<_TempSlot>> all = _slots.values.toList();
    _slots.clear();
    for (final Future<_TempSlot> f in all) {
      await f.then(
        (_TempSlot s) => s.ownerLock.close(),
        onError: (Object _) => null,
      );
    }
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
    final Directory root = _tempRoot ?? await defaultTempRoot();
    _TempSlot slot = await _claimSlot(root);
    if (!await slot.dir.exists()) {
      // 槽位被外部删了（系统清缓存）：放掉旧锁，重新认领一个。
      final String key = root.absolute.path;
      final Future<_TempSlot>? current = _slots[key];
      if (current != null && identical(await current, slot)) {
        _slots.remove(key);
        await slot.ownerLock.close();
      }
      slot = await _claimSlot(root);
    }
    final Directory dir = await slot.dir.createTemp(prefix);
    return File(p.join(dir.path, _blobName));
  }

  Future<void> _deleteTemp(File tmp) async {
    try {
      final parent = tmp.parent;
      if (await tmp.exists()) await tmp.delete();
      if (await parent.exists()) await parent.delete(recursive: true);
    } catch (_) {
      // 临时文件清理失败不影响同步结果；本进程槽位会在它死后被下一个进程整个删掉。
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

/// 本进程在某个临时根下认领的槽位：[dir] 存放本进程的临时目录，[ownerLock] 在进程
/// 存活期间一直持有独占锁（别的进程据此判活）。[sweptDead] 是认领时删掉的死槽位数。
class _TempSlot {
  _TempSlot(this.dir, this.ownerLock, this.sweptDead);

  final Directory dir;
  final RandomAccessFile ownerLock;
  final int sweptDead;
}
