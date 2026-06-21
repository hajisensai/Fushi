import 'dart:async';
import 'dart:io';

import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/remote_book_client.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart'
    show isReservedSyncFolderName;
import 'package:hibiki/src/sync/ttu_models.dart' show DriveFile;

/// 把任意云盘备份后端（Google Drive / WebDAV / OneDrive / Dropbox / FTP / SFTP）
/// 的远端书库适配成书架页的 [RemoteBookClient] 契约（TODO-665 阶段1）。
///
/// 与局域网互联（`HibikiClientSyncBackend`）不同：云盘备份没有 host 实时库 API，
/// 远端书就是根文件夹下每本书一个子文件夹，文件夹内含 `<bookKey>.epub` 内容资产
/// （由同步上传产生）。本适配器把「根文件夹列子项 → 过滤保留区 → 探测每本是否含
/// .epub 内容 → 组装 [RemoteBookInfo]」收敛成 [listRemoteBooks]，把「按 folderId
/// 取首个 .epub 资产并下载到本地」收敛成 [getRemoteBook]（**只下载不导入**，导入由
/// 书架页 `_importRemoteBookFile` 负责，避免双重导入）。
///
/// [backend] **必须**是 `resolveSyncBackend` 的产物（含 `ObfuscatingSyncBackend`
/// 解混淆装饰层），否则下载下来的 .epub 是混淆字节、无法导入。
class CloudRemoteBookClient implements RemoteBookClient {
  CloudRemoteBookClient({
    required this.backend,
    required this.rootFolderId,
    this.contentProbeConcurrency = 4,
  }) : assert(contentProbeConcurrency >= 1);

  /// 远端存储后端；务必是 `resolveSyncBackend` 的产物（带解混淆装饰层）。
  final SyncBackend backend;

  /// 根命名空间定位符（`findOrCreateRootFolder()` 的返回值）。
  final String rootFolderId;

  /// 内容探测（每本书一次 `listChildren`）的并发上限，默认 4：避免串行慢、又不打爆
  /// 云端 API 速率。
  final int contentProbeConcurrency;

  @override
  Future<List<RemoteBookInfo>> listRemoteBooks() async {
    final List<DriveFile> folders = await backend.listBooks(rootFolderId);
    final List<DriveFile> bookFolders = <DriveFile>[
      for (final DriveFile f in folders)
        if (!isReservedSyncFolderName(f.name)) f,
    ];
    // 与对比弹窗一致：把书名→folderId 写进后端缓存（后续删除/上传按缓存定位）。
    backend.cacheBookFolderIds(bookFolders);

    final List<bool> hasContent = await _probeContentBounded(bookFolders);

    return <RemoteBookInfo>[
      for (int i = 0; i < bookFolders.length; i++)
        RemoteBookInfo(
          title: bookFolders[i].name,
          hasContent: hasContent[i],
          // folderId 复用为 downloadId：getRemoteBook 据此 listChildren 取 .epub。
          // 去重按 title 进行（dedupeRemoteBooks），bookKey=folderId 不污染去重。
          bookKey: bookFolders[i].id,
          hasCover: false,
          coverUrl: null,
          hasAudiobook: false,
        ),
    ];
  }

  /// 并发（≤[contentProbeConcurrency]）探测每个书文件夹是否含 `.epub` 内容资产，
  /// 返回与 [folders] 等长、同序的结果。
  Future<List<bool>> _probeContentBounded(List<DriveFile> folders) async {
    final List<bool> results =
        List<bool>.filled(folders.length, false, growable: false);
    int next = 0;

    Future<void> worker() async {
      while (true) {
        final int index = next;
        if (index >= folders.length) return;
        next += 1;
        results[index] = await _remoteFolderHasContent(folders[index].id);
      }
    }

    final int workerCount = folders.length < contentProbeConcurrency
        ? folders.length
        : contentProbeConcurrency;
    await Future.wait(<Future<void>>[
      for (int i = 0; i < workerCount; i++) worker(),
    ]);
    return results;
  }

  /// 该书文件夹是否含可下载的 `.epub` 内容资产。
  ///
  /// 逻辑镜像对比弹窗 / orchestrator 的远端内容查找：列子项找 `.epub`，列举失败
  /// fail-open 返 true，避免一次瞬时网络错误把真实远端书隐藏掉。
  Future<bool> _remoteFolderHasContent(String folderId) async {
    try {
      final List<AssetEntry> children = await backend.listChildren(folderId);
      return children.any((AssetEntry e) =>
          !e.isFolder && e.name.toLowerCase().endsWith('.epub'));
    } catch (_) {
      return true;
    }
  }

  /// 把 [folderId]（= [RemoteBookInfo.downloadId] = 书文件夹定位符）里的首个 `.epub`
  /// 内容资产下载到 [destination]。
  ///
  /// **只下载不导入**：导入由书架页 `_importRemoteBookFile` 负责，不在此调
  /// orchestrator 的合并下载+导入函数（它内含 EPUB 导入器，会双重导入）。
  @override
  Future<void> getRemoteBook(
    String folderId,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    final List<AssetEntry> children = await backend.listChildren(folderId);
    AssetEntry? epub;
    for (final AssetEntry e in children) {
      if (!e.isFolder && e.name.toLowerCase().endsWith('.epub')) {
        epub = e;
        break;
      }
    }
    if (epub == null) {
      throw SyncBackendError(
        'remote book folder has no .epub content: $folderId',
      );
    }
    await backend.getAsset(epub.id, destination, onProgress: onProgress);
  }
}
