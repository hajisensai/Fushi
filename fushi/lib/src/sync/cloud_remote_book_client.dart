import 'dart:async';
import 'dart:io';

import 'package:fushi_core/fushi_core.dart'
    show FushiDatabase, SyncTombstoneKind, TombstoneCloudFolderState;
import 'package:fushi_engine/sync/deletion_propagation.dart'
    show
        deletionTombstoneAssetName,
        deletionTombstoneJson,
        kSyncTombstonesNamespace;
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/cloud_book_content_names.dart';
import 'package:fushi/src/sync/remote_book_client.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart'
    show deleteCloudBookFolder, isReservedSyncFolderName;
import 'package:fushi/src/sync/sync_file_ref.dart' show SyncFileRef;

/// 把任意云盘备份后端（Google Drive / WebDAV / OneDrive / Dropbox / FTP / SFTP）
/// 的远端书库适配成书架页的 [RemoteBookClient] 契约（TODO-665 阶段1）。
///
/// 与局域网互联（`InterconnectSyncBackend`）不同：云盘备份没有 host 实时库 API，
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
    required this.backendType,
    required this.rootFolderId,
    this.database,
    this.contentProbeConcurrency = 4,
    this.contentProbeRetries = 1,
    this.contentProbeRetryBackoff = const Duration(milliseconds: 300),
  }) : assert(contentProbeConcurrency >= 1),
       assert(contentProbeRetries >= 0);

  /// 远端存储后端；务必是 `resolveSyncBackend` 的产物（带解混淆装饰层）。
  final SyncBackend backend;

  /// [backend] 背后的云盘类型。只用于把清单缓存分槽——换后端类型（Drive→WebDAV）
  /// 之后两边的书库毫无关系，必须落在不同槽里（BUG-1202）。由构造方
  /// （已经查过 `getBackendType()`）传入。
  final SyncBackendType backendType;

  /// 根命名空间定位符（`findOrCreateRootFolder()` 的返回值）。
  final String rootFolderId;

  /// 本机库：「从远端删除」要在这里记删除墓碑、写回书名→folderId 持久缓存。
  /// null（只读场景，如找回列表核对远端是否还在）时 [deleteRemoteBook] 拒绝执行。
  final FushiDatabase? database;

  @override
  String get remoteLibrarySourceId =>
      cloudRemoteLibrarySourceId(backendType.name);

  /// 内容探测（每本书一次 `listChildren`）的并发上限，默认 4：避免串行慢、又不打爆
  /// 云端 API 速率。
  final int contentProbeConcurrency;

  /// 内容探测失败（异常/超时）时的有界重试次数（默认 1）：吸收首启 autoSync 与书架
  /// 并发多路打同一 WebDAV 造成的瞬时超时/429。重试用尽仍失败即保守视为「未确证有
  /// 内容」返 false，绝不 fail-open 放出幽灵书（BUG-699 / TODO-1384）。
  final int contentProbeRetries;

  /// 每次内容探测重试前的退避（默认 300ms）：给过载云端喘息，避免同 tick 连打。
  /// 测试可置 [Duration.zero] 保持快速。
  final Duration contentProbeRetryBackoff;

  /// 云盘备份后端：书架远端分区用通用「云端书」文案（非「互联/对端设备」）。
  @override
  RemoteBookSourceKind get remoteSourceKind => RemoteBookSourceKind.cloud;

  @override
  Future<List<RemoteBookInfo>> listRemoteBooks() async {
    final List<SyncFileRef> folders = await backend.listBooks(rootFolderId);
    final List<SyncFileRef> bookFolders = <SyncFileRef>[
      for (final SyncFileRef f in folders)
        if (!isReservedSyncFolderName(f.name)) f,
    ];
    // 与对比弹窗一致：把书名→folderId 写进后端缓存（后续删除/上传按缓存定位）。
    backend.cacheBookFolderIds(bookFolders);

    final List<bool> hasContent = await _probeContentBounded(bookFolders);

    return <RemoteBookInfo>[
      for (int i = 0; i < bookFolders.length; i++)
        RemoteBookInfo(
          // 文件夹名是 sanitizeTtuFilename(title)（`:` → `%3A` 等），必须反解成
          // raw title：下游（书架去重 / 同步 diff / 卡片标题）都按 raw title 再各自
          // 派生 key；直接给文件夹名会被二次 sanitize 成 `%253A`，与本地 bookKey
          // 永远对不上（BUG-2274）。互联 host 那条路本来就返回 raw title。
          title: unsanitizeTtuFilename(bookFolders[i].name),
          hasContent: hasContent[i],
          // folderId 复用为 downloadId：getRemoteBook 据此 listChildren 取 .epub。
          // 去重按 title 进行（dedupeRemoteBooks），bookKey=folderId 不污染去重。
          bookKey: bookFolders[i].id,
          hasEmbeddedCover: false,
          coverUrl: null,
          hasAudiobook: false,
        ),
    ];
  }

  /// 并发（≤[contentProbeConcurrency]）探测每个书文件夹是否含 `.epub` 内容资产，
  /// 返回与 [folders] 等长、同序的结果。
  Future<List<bool>> _probeContentBounded(List<SyncFileRef> folders) async {
    final List<bool> results = List<bool>.filled(
      folders.length,
      false,
      growable: false,
    );
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

  /// 该书文件夹是否**确证**含可下载的 `.epub` 内容资产。
  ///
  /// 保守语义（BUG-699 / TODO-1384）：只有 `listChildren` 成功**且**含 `.epub` 才返
  /// true。「确定无内容」（列举成功但无 .epub）与「探测失败」（异常/超时——首启
  /// autoSync 与书架并发多路打同一 WebDAV 时的超时/429 是主因）**都返 false**：宁可
  /// 真书在网络抖动时暂时不显示、下次刷新/同步再出，也绝不 fail-open 放出无内容 /
  /// 探测不确定的幽灵书。
  ///
  /// 失败时做至多 [contentProbeRetries] 次有界退避重试吸收瞬时抖动；仍失败即 false。
  /// 正确性不依赖重试成功——重试只降低把真书误藏的概率。
  Future<bool> _remoteFolderHasContent(String folderId) async {
    for (int attempt = 0; ; attempt++) {
      try {
        final List<AssetEntry> children = await backend.listChildren(folderId);
        return children.any(
          (AssetEntry e) => !e.isFolder && isRemoteBookContentName(e.name),
        );
      } catch (_) {
        if (attempt >= contentProbeRetries) return false;
        if (contentProbeRetryBackoff > Duration.zero) {
          await Future<void>.delayed(contentProbeRetryBackoff);
        }
      }
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
    // 漫画包新名 `.manga.zip` 优先，其次 `.epub`（EPUB / 旧版漫画包）。
    final AssetEntry? epub = pickRemoteBookContentEntry<AssetEntry>(
      children.where((AssetEntry e) => !e.isFolder),
      (AssetEntry e) => e.name,
    );
    if (epub == null) {
      throw SyncBackendError(
        'remote book folder has no book content: $folderId',
      );
    }
    await backend.getAsset(
      epub.id,
      destination,
      onProgress: syncTransferFractionOnly(onProgress),
    );
  }

  /// 云盘备份没有 host 实时 reader_positions DB，进度走 WebDAV 文件箱
  /// （progress_*.json，由 SyncManager 处理），不走 live 端点。故 live 进度查询恒
  /// 返回 [RemoteBookProgress.empty]（让全量 sweep 在云后端下不改任何东西）。
  @override
  Future<RemoteBookProgress> remoteBookProgress(String bookKey) async =>
      RemoteBookProgress.empty;

  /// 云盘此刻能不能连上（反馈 R8duEiqRuy：远端删除只在来源可达时提供）。
  ///
  /// 列一次同步根——与 [listRemoteBooks] / 删除走同一个后端、同一份凭据，连不上或
  /// 凭据失效在这里如实暴露，而不是等用户确认删除之后才失败。
  Future<RemoteSourceReachability> probeRemoteReachability() async {
    try {
      await backend.listChildren(rootFolderId);
      return RemoteSourceReachability.reachable;
    } on SyncAuthError {
      return RemoteSourceReachability.credentialRejected;
    } on SyncBackendError {
      return RemoteSourceReachability.unreachable;
    } on SocketException {
      return RemoteSourceReachability.unreachable;
    } on TimeoutException {
      return RemoteSourceReachability.unreachable;
    }
  }

  /// 从云盘删除这本书（书架「同时从远端删除」，反馈 R8duEiqRuy）。
  ///
  /// 云盘备份里一本书的全部对象都在它自己的书文件夹里（`sanitizeTtuFilename(书名)`：
  /// 内容包 `.epub` / `.manga.zip`、封面、`progress_` / `statistics_` / `audioBook_`
  /// 元数据 JSON、有声书包 `audiobook.fushiaudio`），跨书的只有合集清单
  /// （`__collections__`，按键引用、不含书本身）。所以删除 = 三步，顺序有讲究：
  ///
  /// 1. **先发布删除墓碑**（`__tombstones__/` 逐条标记，与「从所有设备删除」同一协议）
  ///    并记进本机墓碑表（标已发布，本机下一轮同步把它并进自己的合并清单）。其它设备
  ///    据此：本机还有这本的弹确认是否一并删除；自动同步不再把它推回云盘
  ///    （`SyncOrchestrator` 云通道的推送否决）。墓碑写失败就整体失败，什么都不删。
  /// 2. **再删书文件夹**（各后端的递归删除；六种云盘后端都支持，404 视为已删）。
  ///    文件夹删失败时墓碑已在、文件夹处置状态仍是未处置：意图不丢，书架继续藏这本，
  ///    用户可以重试（重试幂等），云通道下一轮同步也会按记下的文件夹名重试。
  /// 3. 逐出书名→folderId 缓存并写回持久层（BUG-202：陈旧映射会让下次上传打向
  ///    已删的文件夹）。
  ///
  /// [book] 是 [listRemoteBooks] 给出的条目：`downloadId` = 书文件夹定位符，`title` =
  /// 反解后的原书名，墓碑键 = `sanitizeTtuFilename(title)`（= 文件夹名 = 其它设备上
  /// 这本书的 bookKey）。
  Future<void> deleteRemoteBook(RemoteBookInfo book) async {
    final FushiDatabase? db = database;
    if (db == null) {
      throw StateError('CloudRemoteBookClient.deleteRemoteBook needs database');
    }
    final String itemKey = sanitizeTtuFilename(book.title);
    if (itemKey.isEmpty) {
      throw SyncBackendError('remote book has no folder key: ${book.title}');
    }
    final String mediaType = SyncTombstoneKind.book.dbValue;
    final int deletedAt = DateTime.now().millisecondsSinceEpoch;

    final String ns = await backend.ensureNamespace(kSyncTombstonesNamespace);
    await backend.putJsonAsset(
      ns,
      deletionTombstoneAssetName(mediaType, itemKey),
      deletionTombstoneJson(mediaType, itemKey, deletedAt),
    );
    // 文件夹名就是墓碑键（云盘条目的身份本来就是文件夹名）；记下它，删文件夹失败时
    // 云通道下一轮按它重试（`SyncOrchestrator` 墓碑扫描）。
    await db.writeSyncDeletionTombstone(
      mediaType,
      itemKey,
      deletedAt,
      cloudFolderName: itemKey,
    );
    await db.markSyncDeletionPublished(mediaType, itemKey, deletedAt);

    await deleteCloudBookFolder(
      backend: backend,
      db: db,
      folderId: book.downloadId,
    );
    await db.markSyncDeletionCloudFolderState(
      mediaType,
      itemKey,
      TombstoneCloudFolderState.deleted,
    );
  }

  /// 云后端无 live 进度上报通道：no-op（进度由 SyncManager 的文件箱路径处理）。
  @override
  Future<void> putRemoteBookProgress(
    String bookKey,
    RemoteBookProgress progress,
  ) async {}
}
