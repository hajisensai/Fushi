import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:hibiki/src/epub/book_css_repository.dart';
import 'package:hibiki/src/epub/epub_importer.dart';
import 'package:hibiki/src/media/video/video_sidecar.dart'
    show listSidecarSubtitles;
import 'package:hibiki/src/models/local_audio_manager.dart';
import 'package:hibiki/src/sync/collection_manifest.dart';
import 'package:hibiki/src/sync/collection_sync_engine.dart';
import 'package:hibiki/src/sync/deletion_propagation.dart';
import 'package:hibiki/src/sync/interconnect_sync_backend.dart';
import 'package:hibiki/src/sync/interconnect_service_config.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/aggregate_sync_service.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_manager.dart';
import 'package:hibiki/src/sync/sync_progress.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/sync_file_ref.dart';
import 'package:hibiki/src/sync/video_manifest.dart';
import 'package:hibiki_audio/hibiki_audio.dart'
    show FavoriteSentence, FavoriteSentenceRepository;
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

/// Reserved top-level folder (under the backend root) that holds dictionary
/// packages. It lives alongside the per-book folders, so every place that
/// treats root children as *books* must skip it ([isReservedSyncFolderName]).
const String kSyncDictionaryNamespace = '__dictionaries__';

/// Asset file name (inside a book's folder) holding the audiobook package
/// (audio + subtitles + cues + alignment), produced by
/// [SyncAssetPackageService.exportAudioDatabasePackage].
const String kSyncAudiobookAssetName = 'audiobook.hibikiaudio';

const String _dictionaryAssetSuffix = '.hibikidict';

/// Reserved top-level folder holding local-audio source packages (pronunciation
/// DB + config manifest), alongside the dictionary namespace and per-book
/// folders. Must be filtered from any listing that treats root children as
/// books ([isReservedSyncFolderName]).
const String kSyncLocalAudioNamespace = '__local_audio__';

const String _localAudioAssetSuffix = '.hibikiaudiolib';

/// Reserved top-level folder holding the shared collection manifest
/// (`collections.json`) for the collections union sync (多端库联合视图 §2.3).
/// Must be filtered from any listing that treats root children as books
/// ([isReservedSyncFolderName]).
const String kSyncCollectionsNamespace = '__collections__';

/// 旧版**单文件**合集清单资产名（向后兼容读；per-device 布局前所有端共写它）。
/// 现改 per-device `collections-<deviceId>.json`（[collectionsManifestNameFor]）：
/// 单文件读-合-写在两设备并发时后写者整文件覆盖先写者会永久丢墓碑，per-device 各写
/// 各的绝不互相覆盖（沿 `__aggregate__` 成熟范式）。仍读旧单文件做向后兼容合并。
const String kSyncCollectionsManifestName = 'collections.json';

/// 本端自己的 per-device 合集清单资产名。[deviceId] 为空（未配置/测试）时退回旧单
/// 文件名（不产生匿名碎片、且旧行为完全保留）。
String collectionsManifestNameFor(String deviceId) => deviceId.isEmpty
    ? kSyncCollectionsManifestName
    : 'collections-$deviceId.json';

/// 是否是一份合集清单资产（旧单文件 `collections.json` 或 per-device
/// `collections-<id>.json`）——读时据此把命名空间下全部合集清单文件都折进远端并集。
bool isCollectionsManifestName(String name) =>
    name == kSyncCollectionsManifestName ||
    (name.startsWith('collections-') && name.endsWith('.json'));

/// Reserved top-level folder holding uploaded video files + their directory
/// manifest (`videos.json`) for cloud video asset sync (多端库联合视图 §2.6).
/// Populated only when the "上传视频文件" switch is on. Must be filtered from any
/// listing that treats root children as books ([isReservedSyncFolderName]).
const String kSyncVideosNamespace = '__videos__';

/// The single shared video directory manifest asset inside
/// [kSyncVideosNamespace]（读-合并-写；格式见 RemoteVideoManifest）。
const String kSyncVideosManifestName = 'videos.json';

/// True for reserved folder names that are NOT books and must be filtered from
/// any listing of book folders (compare dialog, remote-book import).
///
/// An empty / whitespace-only name is also reserved: it is never a real book
/// folder (a book's folder name is a non-empty sanitized title), and treating it
/// as one would import the sync root itself or an orphan collapsed onto the root
/// (BUG-619, TODO-1329).
bool isReservedSyncFolderName(String name) =>
    name.trim().isEmpty ||
    name == kSyncDictionaryNamespace ||
    name == kSyncLocalAudioNamespace ||
    name == kSyncAggregateNamespace ||
    name == kSyncCollectionsNamespace ||
    name == kSyncVideosNamespace ||
    name == kSyncTombstonesNamespace;

/// Delete a dictionary's package from the remote `__dictionaries__` staging
/// namespace, so deleting a dictionary locally also removes its remote copy
/// instead of leaving an orphan that union-sync re-pulls forever (phantom
/// dictionary + slow sync, BUG-086). Returns whether a remote package was
/// actually deleted (false when none was present). The caller serializes this
/// against in-flight syncs (it mutates the singleton backend's folder cache).
Future<bool> deleteRemoteDictionaryAsset(
  SyncBackend backend,
  String dictionaryName,
) async {
  final String ns = await backend.ensureNamespace(kSyncDictionaryNamespace);
  final AssetEntry? asset = await backend.findAsset(
    ns,
    '$dictionaryName$_dictionaryAssetSuffix',
  );
  if (asset == null) return false;
  await backend.deleteAsset(asset.id);
  return true;
}

/// One sync item judged a genuine fork (both sides moved off the common-ancestor
/// baseline) and therefore skipped instead of auto-resolved. Carries everything
/// a later resolution prompt needs, including both versions so [fingerprint] can
/// dedup re-surfacing of the same conflict.
class SyncConflict {
  SyncConflict({
    required this.assetKey,
    required this.dimension,
    required this.title,
    this.localVersion,
    this.remoteVersion,
  });

  final String assetKey;
  final String dimension;
  final String title;
  final int? localVersion;
  final int? remoteVersion;

  /// 去重指纹：资产+维度+两端版本。两端任一版本变化即视为新冲突。
  String get fingerprint => '$assetKey|$dimension|$localVersion|$remoteVersion';
}

/// Tally of what one orchestrated run transferred. `errors` collects per-item
/// failures that were skipped without aborting the whole run. `conflicts`
/// collects items judged a genuine fork and skipped without auto-resolving —
/// they are neither failures nor transfers, so they never feed `booksImported`
/// nor `errors`.
class SyncRunReport {
  int booksImported = 0;
  int dictionariesImported = 0;
  int dictionariesExported = 0;
  int audiobooksImported = 0;
  int audiobooksExported = 0;
  int localAudioImported = 0;
  int localAudioExported = 0;

  /// 本轮推到云 `__videos__/` 命名空间的视频文件数（多端库联合视图 §2.6）。上传语义
  /// （export-only），不产生本地导入，故不计入 [needsLocalLibraryRefresh]——与
  /// [audiobooksExported] / [dictionariesExported] 同律。
  int videosExported = 0;

  /// Book reading positions pulled from the interconnect host into this device's
  /// local `reader_positions` this run (host→local, newer-wins). A progress-only
  /// pull writes no *content*, so it never bumps [booksImported]; yet the shelf's
  /// cached `hibikiBooksProvider` still holds the pre-sync progress and must be
  /// invalidated. Otherwise synced book progress lands in the DB but stays
  /// invisible on the shelf until app restart (BUG-686: user saw "book progress
  /// didn't sync" while audiobook resume worked — resume re-reads its pref at
  /// play time, whereas the shelf progress bar is a cached snapshot of
  /// reader_positions).
  int localBookProgressPulled = 0;

  /// Per-book metadata/cover files that had spilled directly into the sync root
  /// and were swept back out this run (BUG-619 re-report / TODO-1340). Purely a
  /// cleanup counter — spill removal is neither an import nor a failure, so it
  /// never feeds [needsLocalLibraryRefresh] nor [errors].
  int rootSpillFilesRemoved = 0;

  /// 本轮合集同步在本地应用了变更的合集数（多端库联合视图 §2.3：成员并集/墓碑/
  /// 手动序 LWW 落进本地 DB 的合集条目数）。>0 时书架合集行/详情页需要刷新，
  /// 故计入 [needsLocalLibraryRefresh]。
  int collectionsUpdated = 0;

  /// Host-owned external-service preferences imported over the authenticated
  /// interconnect channel. These require an AppModel preference-cache refresh
  /// even though no media row was imported.
  int serviceConfigsImported = 0;

  final List<String> errors = <String>[];

  /// 本轮遇到的**鉴权类**失败，带类型（去重后）。BUG-1324。
  ///
  /// [errors] 是扇平成字符串的日志行：异常一旦拼进去，「凭据真的不对」和
  /// 「服务端因别的原因拒绝」就再也分不出来了；而 UI 只数了个
  /// `errors.length` 就变成「N 项失败」，等于把两件事押成同一句废话。
  /// 本列表把类型保留到 UI，与 [errors] **并存**（日志行一字不变）。
  final List<SyncAuthFailure> authFailures = <SyncAuthFailure>[];

  final List<SyncConflict> conflicts = <SyncConflict>[];

  /// 本轮消费远端删除标记算出的 deleteLocal 候选（远端已删 ∧ 本地仍在库，且
  /// deletedAt > 本设备删除墓碑消费基线）。orchestrator 无 BuildContext 不直接删，
  /// 塞进本列表经 onReport 回调（[AppModel.presentDeletionCandidates]）弹逐条确认框，
  /// 用户勾选后才删本地。与 [conflicts] 同律：既非导入也非失败，不进任何计数。
  final List<DeletionPropagationCandidate> deletionCandidates =
      <DeletionPropagationCandidate>[];

  /// 本轮呈现的删除候选里最大的远端 deletedAt。UI 层在用户处理完确认框后据此推进
  /// [SyncRepository.setDeletionTombstonesBaselineMs]（=已复核到此时刻的删除标记），
  /// 恰好压制已复核的、放行更新的删除。0 = 本轮无候选。
  int deletionTombstonesHighWaterMs = 0;

  /// True when the run imported data into this device's local library caches or
  /// visible shelves. Export-only runs mutate the remote side and do not need a
  /// local refresh.
  bool get needsLocalLibraryRefresh =>
      booksImported > 0 ||
      dictionariesImported > 0 ||
      audiobooksImported > 0 ||
      localAudioImported > 0 ||
      localBookProgressPulled > 0 ||
      collectionsUpdated > 0 ||
      serviceConfigsImported > 0;

  /// 合并另一条通道的报告到本报告（option B 双通道：云备份 + 互联并行各跑一轮后，
  /// 汇总成单一报告返回）。累加所有计数、拼接错误与冲突列表。
  void mergeFrom(SyncRunReport other) {
    booksImported += other.booksImported;
    dictionariesImported += other.dictionariesImported;
    dictionariesExported += other.dictionariesExported;
    audiobooksImported += other.audiobooksImported;
    audiobooksExported += other.audiobooksExported;
    localAudioImported += other.localAudioImported;
    localAudioExported += other.localAudioExported;
    videosExported += other.videosExported;
    localBookProgressPulled += other.localBookProgressPulled;
    rootSpillFilesRemoved += other.rootSpillFilesRemoved;
    collectionsUpdated += other.collectionsUpdated;
    serviceConfigsImported += other.serviceConfigsImported;
    errors.addAll(other.errors);
    for (final SyncAuthFailure f in other.authFailures) {
      _addAuthFailure(f);
    }
    conflicts.addAll(other.conflicts);
    deletionCandidates.addAll(other.deletionCandidates);
  }

  /// 记一条维度/条目级失败。
  ///
  /// 字符串照旧进 [errors]（`'$label: $error'` —— 与改动前逐字相同，
  /// 既有日志/断言一行不变）；它若是 [SyncAuthError]，**额外**在
  /// [authFailures] 里留一份带类型的。信息只增不减。
  void noteError(String label, Object error) {
    errors.add('$label: $error');
    if (error is! SyncAuthError) return;
    _addAuthFailure(SyncAuthFailure(
      label: label,
      kind: error.kind,
      message: error.message,
      serverReason: error.serverReason,
    ));
  }

  /// 按（kind, message, serverReason）去重：一次 401 会让一轮里几百本书逐本
  /// 失败，用户只需要知道「凭据被拒了」一次。label 不进去重键（它只是
  /// 第一个撞上的现场），否则去重就形同虚设。
  void _addAuthFailure(SyncAuthFailure failure) {
    final bool seen = authFailures.any((SyncAuthFailure f) =>
        f.kind == failure.kind &&
        f.message == failure.message &&
        f.serverReason == failure.serverReason);
    if (!seen) authFailures.add(failure);
  }
}

/// 一次鉴权类同步失败，带着它的真实语义（BUG-1324）。
///
/// 与 [SyncAuthError] 同形，但是一个**值**：它要跨 orchestrator → 报告 → UI
/// 三层活下来，而异常在第一个 catch 里就死了。
class SyncAuthFailure {
  const SyncAuthFailure({
    required this.label,
    required this.kind,
    required this.message,
    this.serverReason,
  });

  /// 出错的维度/条目标签，与 [SyncRunReport.errors] 里那一行同前缀。
  final String label;

  final SyncAuthFailureKind kind;
  final String message;

  /// 服务端给出的拒绝原因原文（只有 403 常带）。
  final String? serverReason;

  /// 服务端按策略拒绝（403），而不是凭据不被接受（401）。
  bool get isForbidden => kind == SyncAuthFailureKind.forbidden;
}

/// Orchestrates sync across any [SyncBackend].
///
/// Layers the three previously-missing capabilities on top of the existing
/// per-book [SyncManager] (progress / stats / content / audiobook position),
/// which is left unchanged:
///   1. upload local book files when enabled;
///   2. dictionary packages (push/pull in the `__dictionaries__` namespace);
///   3. sync local audiobook packages when enabled (interconnect: bidirectional,
///      see [_syncAudiobooksLive]; cloud backend: upload-only).
///
/// Book content switches are upload-only: remote-only EPUBs stay remote until the
/// user explicitly downloads them from the compare or interconnect UI. Audiobooks
/// over the interconnect live API are bidirectional (TODO-809) but pull only into
/// books the device already owns (no orphan audiobook rows; remote audiobooks for
/// unknown books still wait for manual download). Deletes are never propagated.
/// Dictionaries and local-audio sources remain union-synced because they are
/// separate opt-in sharing pools.
class SyncOrchestrator {
  SyncOrchestrator({
    required HibikiDatabase db,
    required SyncBackend backend,
    required Directory dictionaryResourceRoot,
    required Directory audioDatabaseRoot,
    required Directory tempDir,
    this.deviceId = '',
    required this.syncStats,
    required this.syncAudioBookPosition,
    required this.syncContent,
    required this.syncAudioBookFiles,
    this.syncVideoFiles = false,
    required this.syncDictionary,
    required this.syncLocalAudio,
    this.localAudioEntries = const <LocalAudioDbEntry>[],
    this.onLocalAudioImported,
    this.statsSyncMode = StatisticsSyncMode.merge,
    this.onProgress,
  })  : _db = db,
        _backend = backend,
        _dictionaryResourceRoot = dictionaryResourceRoot,
        _audioDatabaseRoot = audioDatabaseRoot,
        _tempDir = tempDir,
        _packages = SyncAssetPackageService(db: db);

  final HibikiDatabase _db;
  final SyncBackend _backend;
  final Directory _dictionaryResourceRoot;
  final Directory _audioDatabaseRoot;
  final Directory _tempDir;
  final SyncAssetPackageService _packages;

  /// This device's stable id (SyncRepository.getOrCreateDeviceId). Names this
  /// device's own snapshot asset in the cloud `__aggregate__` namespace so two
  /// devices never clobber each other's aggregate snapshot (TODO-1056 phase B).
  /// Defaults to '' for callers that do not sync the aggregate dimension (e.g.
  /// tests of other dimensions); an empty id skips aggregate sync as a no-op.
  final String deviceId;

  final bool syncStats;
  final bool syncAudioBookPosition;
  final bool syncContent;
  final bool syncAudioBookFiles;

  /// 是否把本地视频文件上传到云 `__videos__/` 命名空间（多端库联合视图 §2.6）。默认
  /// false：视频体积大，须用户显式 opt-in。仅云后端生效（互联走 host API，暂不接线）。
  final bool syncVideoFiles;

  final bool syncDictionary;

  /// 是否同步本地音频来源（DB 文件 + 配置）。orchestrator 不依赖 AppModel：导出用的
  /// 条目列表由 [localAudioEntries] 注入，导入注册经 [onLocalAudioImported] 回调。
  final bool syncLocalAudio;
  final List<LocalAudioDbEntry> localAudioEntries;
  final Future<void> Function(LocalAudioPackageContents)? onLocalAudioImported;

  final StatisticsSyncMode statsSyncMode;

  /// Optional progress sink (manual sync only). Null for background auto-sync,
  /// which keeps its old silent behaviour.
  final SyncProgressCallback? onProgress;

  void _emit(
    SyncPhase phase, {
    required int itemIndex,
    required int itemTotal,
    String? title,
    double? fileFraction,
  }) {
    final cb = onProgress;
    if (cb == null) return;
    cb(SyncProgress(
      phase: phase,
      itemIndex: itemIndex,
      itemTotal: itemTotal,
      title: title,
      fileFraction: fileFraction,
    ));
  }

  int _tmpCounter = 0;

  File _tmpFile(String suffix) {
    _tmpCounter++;
    return File(p.join(_tempDir.path, 'hibiki_sync_$_tmpCounter$suffix'));
  }

  /// Runs the full sweep. File-content switches are upload-only: remote-only
  /// books/audiobooks stay remote until the user explicitly downloads them.
  /// Existing local books still go through [SyncManager], so progress,
  /// statistics, and audiobook-position conflicts remain visible.
  Future<SyncRunReport> run() async {
    final SyncRunReport report = SyncRunReport();
    final String root = await _backend.findOrCreateRootFolder();

    // BUG-619 re-report / TODO-1340: sweep any per-book metadata/cover files
    // that spilled directly into the sync root (from the old empty-title
    // `ensureBookFolder('')` collapse, before TODO-1329 blocked it at the
    // source). TODO-1329 stops new spills but never cleaned the accumulated
    // residue, which piles into many duplicate copies. Runs before the per-book
    // sweep so a spilled `progress_*` in the root can't be mistaken for a book's
    // remote state.
    await pruneRootSpill(root, report);

    // 书籍文件开关是上传语义：只把本端已有 epub 内容补到远端。
    // 远端独有书不会在自动同步中导入本机，必须通过 compare/interconnect UI 点击下载。
    final SyncBackend b = _backend;
    final bool isInterconnect = b is InterconnectSyncBackend;

    if (isInterconnect) {
      await _syncServiceConfigLive(report, b);
      // 互联内容（epub）走 live 端点，仅当 syncContent 开时执行。
      // 元数据（进度/统计/有声书位置）由下方 SyncManager 以 syncContent=false 处理。
      if (syncContent) {
        await _syncBooksContentLive(report, b);
      }
    }

    // Existing per-book progress / stats / content / audiobook-position sync
    // for every local book (now including any just-imported remote books).
    //
    // 互联分支传 syncContent=false：epub 内容已由 _syncBooksContentLive 接管，
    // 避免 SyncManager 再次经书文件夹路径重复传 epub。
    // 进度/统计/有声书位置不受 syncContent 影响，仍正常同步。
    //
    // 注意：音频文件（有声书 .m4a/.mp3 等）在 SyncManager 里也被 syncContent 门控
    // （_exportContentIfMissing / _importContentIfMissing 同时处理 epub + 音频）。
    // 互联下有声书文件走 syncAudioBookFiles（hibikiaudio 包路径），不走此处，
    // 故互联分支传 syncContent=false 不会丢失音频同步。Phase 3 如需独立接管
    // 音频文件 live 同步，请参考本方法的分流模式扩展。
    final bool managerSyncContent = isInterconnect ? false : syncContent;

    int readingDone = 0;
    int readingTotal = 0;
    String? readingTitle;
    final List<SyncBookResult> bookResults = await SyncManager(
      db: _db,
      backend: _backend,
      onContentProgress: (double f) => _emit(SyncPhase.readingData,
          itemIndex: readingDone,
          itemTotal: readingTotal,
          title: readingTitle,
          fileFraction: f),
    ).syncAllBooks(
      syncStats: syncStats,
      statsSyncMode: statsSyncMode,
      syncAudioBook: syncAudioBookPosition,
      syncContent: managerSyncContent,
      onBookProgress: (int done, int total, String title) {
        readingDone = done;
        readingTotal = total;
        readingTitle = title;
        _emit(SyncPhase.readingData,
            itemIndex: done, itemTotal: total, title: title);
      },
    );
    _collectConflicts(bookResults, report);

    if (syncDictionary) await syncDictionaries(report);

    // 互联（InterconnectSyncBackend）本地音频 + 有声书包走 live 端点；
    // 云后端仍走原 __local_audio__ 暂存路径（不变）。
    if (isInterconnect) {
      if (syncLocalAudio) await _syncLocalAudioLive(report, b);
      if (syncAudioBookFiles) await _syncAudiobooksLive(report, b);
      // 互联视频文件 live push（client→host）：单文件本地视频经 host 上传端点注册进
      // host 视频库。与云后端 syncVideoAssets 同为 syncVideoFiles 开关驱动、同为
      // upload-only（host→client 仍走按需流式/下载）。
      if (syncVideoFiles) await _syncVideosLive(report, b);
    } else {
      if (syncLocalAudio) await syncLocalAudioPackages(report);
      if (syncAudioBookFiles) await syncAudiobookPackages(root, report);
      // 云视频资产上传（多端库联合视图 §2.6）：仅云后端走 __videos__ 伪装资产。互联
      // 视频文件走上面 _syncVideosLive 的 host API 上传，不走此云后端分支。
      if (syncVideoFiles) await syncVideoAssets(report);
    }

    // 互联书籍 + 视频进度走 live 端点双向同步（TODO-767）。
    //
    // 书籍：上面 SyncManager 走的 WebDAV 文件箱进度（progress_*.json）host 端
    // 从不回灌自己的 reader_positions DB（互联角色非对称：跑 sync 的是 client，
    // host 只跑 server），故「立即同步」点了进度不过去。这里对称视频 TODO-653 补
    // 书籍进度 live 端点：遍历本地 epub 书逐本 PUT 本地进度到 host DB + GET host
    // 进度回灌本地（取较新时间戳）。
    //
    // 视频：进度此前只在打开远端视频时按需同步（resume 路径），不进全量 sweep。
    // 这里遍历本地 VideoBooks 推/拉 lastPositionMs，让「立即同步」一次把书+视频
    // 进度都同步。
    if (isInterconnect) {
      await _syncBookProgressLive(report, b);
      await _syncVideoProgressLive(report, b);
      await _syncAudiobookProgressLive(report, b);
      // 互联聚合（统计 + 收藏）live 双向合并（TODO-1056 phase C）。复用 syncStats
      // 开关（聚合 = 统计 + 收藏，同属「统计同步」语义，不新增设置项 / schema）。
      // 互联无 per-device 快照文件、不依赖 deviceId：host 单份权威快照，client GET →
      // 并集折叠 → 写回本地 → PUT 回 host（host 再 MAX/并集折叠进自己 DB）。
      if (syncStats) await _syncAggregateLive(report, b);
    }

    // 云后端聚合同步（统计 + 收藏跨端共享，TODO-1056 phase B）。互联 live 端点
    // 是 phase C，这里只做云后端这一条通道，且复用 syncStats 开关（聚合 =
    // 统计 + 收藏，同属「统计同步」语义，不新增设置项 / schema）。
    // deviceId 为空（测试构造 / 未配置）时跳过：聚合快照按 deviceId 命名，无 id
    // 无法安全落每设备快照，降级为 no-op（绝不崩，绝不写错名快照）。
    if (!isInterconnect && syncStats && deviceId.isNotEmpty) {
      await _syncAggregate(report);
    }

    // 合集双向同步（多端库联合视图 §2.3）：
    // - 云后端走 sync 根下 `__collections__/collections.json` 共享清单的读-合并-写；
    // - 互联（InterconnectSyncBackend）走 host API `/api/library/collections` 端点
    //   （任务5/6，目录接口带合集归属 + 清单读写），不走 WebDAV 文件箱伪装的
    //   __collections__ 资产（互联 backend 的资产层是 live 端点适配，语义不同）。
    // 两条通道调用同一 CollectionSyncEngine.merge / applyCollectionLocalChanges，
    // 成员并集 + 移出/删除墓碑 + 手动序整合集 LWW，仅通道不同。
    if (isInterconnect) {
      await _syncCollectionsLive(report, b);
    } else {
      await syncCollections(report);
    }

    // 删除传播墓碑（显式确认式）：发布本机未发布删除标记 + 消费远端标记算 deleteLocal
    // 候选（塞 report，UI 弹逐条确认）。放合集之后、冷却戳之前：本地在库键此刻最稳定，
    // 且中断则下轮重跑。基线不在此推进（见 syncDeletionTombstones 文档）。
    if (isInterconnect) {
      await _syncDeletionTombstonesLive(report, b);
    } else {
      await syncDeletionTombstones(report);
    }

    // TODO-1332: 只有整轮 sweep 完整跑到这里（书 / 词典 / 本地音频 / 有声书 / live 进度
    // / 聚合等所有阶段都已尝试、未被异常 / app 退出 / 进程终止打断）才记录同步冷却
    // 时间戳。中断发生在本行之前 → lastSyncMs 保持不变，使下次 app-open 自动同步不被
    // 冷却窗（[_syncCooldownMs]）压制、整轮重试——即「同步没完成就丢弃中间态、下次
    // 启动再同步」。此前该时间戳写在 SyncManager.syncAllBooks 书阶段末尾（sweep 中途），
    // 书阶段后被打断的残缺同步会误记冷却、错误地压制下次重试。
    await SyncRepository(_db)
        .setLastSyncMs(DateTime.now().millisecondsSinceEpoch);
    return report;
  }

  /// 云后端聚合同步：把本机统计 + 收藏经 [AggregateSyncService] 与其它设备的
  /// per-device 快照并集合并（只增不减 / 值不缩小 / 幂等 / 并集），写回本地并
  /// 上传本机最新快照。无 baseline / 无冲突弹窗（集合 + 单调语义无损）。首次同步
  /// （云上无 `__aggregate__` 快照）优雅退化为「只上传本机快照」，不崩。
  ///
  /// 整段包在 try/catch 里，逐轮错误进 [report.errors] 不中断整体 sweep（与其它
  /// 维度同纪律）。删除不跨端传播；无 schema 变更。
  Future<void> _syncAggregate(SyncRunReport report) async {
    try {
      await AggregateSyncService(_db).sync(
        store: _backend,
        deviceId: deviceId,
      );
    } catch (e) {
      report.noteError('aggregate sync', e);
    }
  }

  /// Pulls the host's explicitly allowlisted service configuration. The host is
  /// authoritative for keys it publishes; no client→host write exists.
  Future<void> _syncServiceConfigLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    try {
      final InterconnectServiceConfigSnapshot? snapshot =
          await backend.getRemoteServiceConfig();
      if (snapshot == null) return;
      report.serviceConfigsImported += await snapshot.applyTo(_db);
    } catch (e) {
      report.noteError('service config live sync', e);
    }
  }

  /// 互联聚合（统计 + 收藏）live 双向合并（TODO-1056 phase C）。
  ///
  /// 复用 [AggregateSyncService.syncOverClient] 的通道无关核心（materialize 本地 →
  /// GET host 快照 → [AggregateMergeService] 并集折叠 → 写回本地 DB（只 MAX / 并集
  /// upsert，幂等）→ PUT 合并后快照回 host）。IO 由本方法注入：GET 走
  /// [InterconnectSyncBackend.getRemoteAggregate]（老 host 无端点返回 404 → null →
  /// 只推不拉，优雅降级），PUT 走 [InterconnectSyncBackend.putRemoteAggregate]。
  ///
  /// 无 baseline / 无冲突弹窗（集合 + 单调语义无损）；删除不跨端传播；无 schema 变更。
  /// 整段 try/catch，逐轮错误进 [report.errors] 不中断整体 sweep（与其它维度同纪律）。
  Future<void> _syncAggregateLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    try {
      await AggregateSyncService(_db).syncOverClient(
        fetchRemote: backend.getRemoteAggregate,
        pushMerged: backend.putRemoteAggregate,
      );
    } catch (e) {
      report.noteError('aggregate live sync', e);
    }
  }

  /// 测试入口：直接调用 [_syncAggregateLive]（private 方法对测试文件不可见）。
  @visibleForTesting
  Future<void> syncAggregateLiveForTest(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) =>
      _syncAggregateLive(report, backend);

  /// 合集双向同步（多端库联合视图 §2.3 任务4，云后端通道）。
  ///
  /// 读远端 `__collections__/collections.json` 共享清单（无则视为空清单，首轮
  /// 优雅退化为「只上传本机合集」）→ [CollectionSyncEngine.merge] 与本地全量
  /// 快照合并（成员并集 + 移出/删除墓碑按基线裁决 + 手动序整合集 LWW）→
  /// [applyCollectionLocalChanges] 把本地变更集落 DB → 合并后清单与远端字节
  /// 不同才回写（确定性排序保证内容相等 ⇒ 字节相等，避免每轮写放大）。
  ///
  /// 基线（[SyncRepository.getCollectionsSyncBaselineMs]）在整轮成功后才推进：
  /// 中途失败保持旧基线，下轮把同一批墓碑重新当「新闻」裁决——应用端按目标态
  /// 调和，重放幂等，不会重复删除/复活。
  ///
  /// 整段 try/catch，错误进 [report.errors] 不中断整体 sweep（与其它维度同纪律）。
  /// 只跑合集维度的轻量同步（合集变更防抖触发用，见 sync_auto_trigger 的
  /// `installCollectionsSyncWatcher`）。
  ///
  /// 与 [run] 的合集段完全同路：互联走 host live 端点（[_syncCollectionsLive]），
  /// 云后端走 `__collections__` per-device 清单（[syncCollections]）；两者内部
  /// 自捕获异常进 [SyncRunReport.errors]。**不写** lastSyncMs 冷却戳——那是完整
  /// sweep 的语义（TODO-1332），轻量路径不得压制下一次 app-open 全量同步。
  Future<SyncRunReport> runCollectionsOnly() async {
    final SyncRunReport report = SyncRunReport();
    final SyncBackend b = _backend;
    if (b is InterconnectSyncBackend) {
      await _syncCollectionsLive(report, b);
    } else {
      // 云路径的 ensureNamespace 依赖同步根已解析（与 [run] 开头一致）。
      await _backend.findOrCreateRootFolder();
      await syncCollections(report);
    }
    return report;
  }

  Future<void> syncCollections(SyncRunReport report) async {
    try {
      final String ns =
          await _backend.ensureNamespace(kSyncCollectionsNamespace);
      final SyncRepository repo = SyncRepository(_db);

      // 竞态修复：**读远端清单之前**先预取本轮基线时刻，整轮成功后写这个预取值
      // （而非结束时的新 now）。否则「IO 期间用户移出的墓碑 removedAt <= 结束才取的
      // now」会在下轮被判旧闻撤销。同时作 publishedAt 发布时戳 + 本端文件 lastWrittenAt。
      final int nextBaseline = DateTime.now().millisecondsSinceEpoch;

      // per-device 布局：本端只写 `collections-<deviceId>.json`，读时合并**命名空间下
      // 全部清单文件（含本端上轮自己那份 + 旧单文件）**成远端并集。单文件读-合-写两
      // 设备并发后写者整文件覆盖先写者会永久丢墓碑；per-device 各写各的绝不互相覆盖。
      // 折叠里**包含本端自己上轮那份**——保真已发布墓碑戳、字节稳定（幂等）。
      final String ownName = collectionsManifestNameFor(deviceId);
      final List<AssetEntry> children = await _backend.listChildren(ns);

      final List<CollectionManifest> peers = <CollectionManifest>[];
      bool ownExists = false;
      bool ownCorrupt = false; // 本端自己那份读不出：自愈重写（finding 2）。
      bool skippedPeer = false; // 跳过了他端损坏文件：本轮不推进基线（finding 2）。
      String? ownCanonical; // 本端上轮那份的内容字节（回写去重用，内容不变不回写）。
      AssetEntry? legacySingle; // 旧单文件 collections.json（per-device 布局前遗留）。
      for (final AssetEntry e in children) {
        if (e.isFolder || !isCollectionsManifestName(e.name)) continue;
        final bool isOwn = e.name == ownName;
        if (e.name == kSyncCollectionsManifestName &&
            ownName != kSyncCollectionsManifestName) {
          legacySingle = e; // 记下旧单文件，吸收其知识后删除（finding 1）。
        }
        try {
          final Object? json = await _backend.getJsonAsset(e.id);
          if (json == null) {
            throw const FormatException('unreadable (null decode)');
          }
          final CollectionManifest m = CollectionManifest.fromJson(json);
          peers.add(m);
          if (isOwn) {
            ownExists = true;
            ownCanonical = m.canonicalJson();
          }
        } catch (err) {
          // finding 2 自愈：坏文件是本端自己那份 → 不 abort，按其余可读对端 + 本地照常
          // 合并并回写自己那份（覆盖损坏）；坏文件是他端 → 跳过该文件继续本轮（记
          // report.errors），且**不推进基线**（没读到那份的墓碑下轮仍当新闻裁决，避免
          // 基线越过未读知识造成误判）。任一情况都绝不整轮 return。
          if (isOwn) {
            ownCorrupt = true;
            report.noteError(
                'own collections manifest "${e.name}" unreadable;'
                ' republishing from local+peers this run (self-heal)',
                err);
          } else {
            skippedPeer = true;
            report.noteError(
                'peer collections manifest "${e.name}" '
                'unreadable; skipped this run (baseline held)',
                err);
          }
        }
      }

      final CollectionManifest local = await loadLocalCollectionManifest(_db);

      // 时钟回拨钳制：持久化基线晚于 now（时钟被拨回）时钳到 now，避免基线永远大于
      // 一切 publishedAt/removedAt 而把所有墓碑当旧闻。
      int baseline = await repo.getCollectionsSyncBaselineMs();
      if (baseline > nextBaseline) baseline = nextBaseline;

      // 折叠对端 per-device 文件 + 旧单文件成远端并集（按文件级 lastWrittenAt 裁决墓碑，
      // 见 combinePeers）。空并集 = 首轮/无对端，优雅退化为「只上传本机」。
      final CollectionManifest remote =
          CollectionSyncEngine.combinePeers(peers);

      final CollectionSyncOutcome outcome = CollectionSyncEngine.merge(
        local: local,
        remote: remote,
        lastSyncedAtMs: baseline,
        nowMs: nextBaseline,
      );

      report.collectionsUpdated +=
          await applyCollectionLocalChanges(_db, outcome.changes);

      // 回写门槛：本端 per-device 文件内容有变才写自己那份；本端尚无文件且合并结果为空
      // （零合集库）不无中生有地创建空文件；但本端文件损坏时强制回写以自愈。只写 ownName
      // ——绝不覆盖别人的文件。写时盖 lastWrittenAt=nextBaseline（发布时刻），供对端折叠裁决。
      final bool nothingToPublish =
          !ownExists && !ownCorrupt && outcome.merged.collections.isEmpty;
      bool ownWritten = false;
      if (!nothingToPublish && outcome.merged.canonicalJson() != ownCanonical) {
        await _backend.putJsonAsset(ns, ownName,
            outcome.merged.withLastWrittenAt(nextBaseline).toJson());
        ownWritten = true;
      }

      // finding 1：本端 per-device 文件此刻已承载吸收后的并集知识（读到的旧单文件已折进
      // outcome.merged），删除旧单文件 collections.json，消除永不重写/删除的永久陈旧活
      // 成员源。仅本端文件此刻存在时删除；legacySingle 只在 deviceId 非空（ownName != 旧
      // 单文件名）时被赋值，故绝不误删本端自己那份。
      if (legacySingle != null && (ownExists || ownWritten)) {
        await _backend.deleteAsset(legacySingle.id);
      }

      // finding 2：跳过了任一他端损坏文件 ⇒ 本轮没读全知识，不推进基线。本端自愈不算
      // （本端知识来自本地 DB，未依赖那份损坏文件）。
      if (!skippedPeer) {
        await repo.setCollectionsSyncBaselineMs(nextBaseline);
      }
    } catch (e) {
      report.noteError('collections sync', e);
    }
  }

  /// 合集双向同步（多端库联合视图 §2.3 任务5.3，互联 host API 通道）。
  ///
  /// 读-合并-写，与云后端 [syncCollections] 完全同构，仅通道不同（host API 而非
  /// WebDAV `__collections__` 文件箱）：GET host 合集清单
  /// （[InterconnectSyncBackend.getRemoteCollectionManifest]）→ [CollectionSyncEngine.merge]
  /// 与本地全量快照合并（成员并集 + 移出/删除墓碑按基线裁决 + 手动序整合集 LWW）→
  /// [applyCollectionLocalChanges] 落本地 DB（计入 [SyncRunReport.collectionsUpdated]）→
  /// 合并后清单与 host 字节不同才 POST 回写（host 端再经 mergeCollectionManifest 并入
  /// 自己 DB，同一引擎）。
  ///
  /// 老 host 无端点（GET 404 → null）时优雅跳过（不 POST，不崩）。基线（本端
  /// [SyncRepository.getCollectionsSyncBaselineMs]）在整轮成功后才推进；中途失败保持
  /// 旧基线，下轮同一批墓碑重当「新闻」裁决——应用端按目标态调和幂等重放安全。
  /// 整段 try/catch，错误进 [report.errors] 不中断整体 sweep（与其它维度同纪律）。
  Future<void> _syncCollectionsLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    try {
      // 竞态修复：读远端清单**之前**先预取本轮基线时刻，整轮成功后写这个预取值
      // （而非结束时的新 now），并作 publishedAt 发布时戳。
      final int nextBaseline = DateTime.now().millisecondsSinceEpoch;
      final CollectionManifest? remote =
          await backend.getRemoteCollectionManifest();
      if (remote == null) {
        // 老 host 无 /api/library/collections 端点（对端 app 版本过旧）。以前静默
        // return，用户只看见「合集没同步」却无任何线索（BUG-938 次因）。计入
        // report.errors：错误日志留痕 + 手动「立即同步」按错误计数提示；其余维度
        // 不受影响照常同步。
        report.errors.add(
            'collections live sync: host has no collections endpoint '
            '(older app version) — update the host app to sync collections');
        return;
      }

      final CollectionManifest local = await loadLocalCollectionManifest(_db);
      final SyncRepository repo = SyncRepository(_db);
      // 时钟回拨钳制：持久化基线晚于 now 时钳到 now。
      int baseline = await repo.getCollectionsSyncBaselineMs();
      if (baseline > nextBaseline) baseline = nextBaseline;
      final CollectionSyncOutcome outcome = CollectionSyncEngine.merge(
        local: local,
        remote: remote,
        lastSyncedAtMs: baseline,
        nowMs: nextBaseline,
      );

      report.collectionsUpdated +=
          await applyCollectionLocalChanges(_db, outcome.changes);

      // 回写门槛：字节有变才 POST（确定性排序保证内容相等 ⇒ 字节相等，避免每轮
      // 无谓写放大）。
      if (outcome.merged.canonicalJson() != remote.canonicalJson()) {
        await backend.putRemoteCollectionManifest(outcome.merged);
      }
      await repo.setCollectionsSyncBaselineMs(nextBaseline);
    } catch (e) {
      report.noteError('collections live sync', e);
    }
  }

  /// 测试入口：直接调用 [_syncCollectionsLive]（private 方法对测试文件不可见）。
  @visibleForTesting
  Future<void> syncCollectionsLiveForTest(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) =>
      _syncCollectionsLive(report, backend);

  /// 收集本设备当前在库的资产键（按 mediaType 分组），供删除墓碑消费端算 deleteLocal
  /// 候选（远端有删除标记 ∧ 本地仍在库）。itemKey 与写墓碑点严格一致：book/audiobook =
  /// bookKey（[writeSyncDeletionTombstone] 调用点 reader_hibiki_source / audiobook），
  /// video = bookUid（video_book_repository），localaudio = displayName，
  /// srtbook = srt_books.uid（仅 standalone，见下）。
  ///
  /// 键一律用 [SyncTombstoneKind.dbValue] 而非裸字符串字面量：这张 map 与写墓碑点必须
  /// 逐字一致，拼错一个字符的后果是「对端删了、本地永远不弹确认」这种静默失效。
  Future<Map<String, Set<String>>> _collectPresentDeletionKeys() async {
    return <String, Set<String>>{
      SyncTombstoneKind.book.dbValue: <String>{
        for (final EpubBookRow r in await _db.getAllEpubBooks()) r.bookKey,
      },
      SyncTombstoneKind.audiobook.dbValue: <String>{
        for (final AudiobookRow r in await _db.getAllAudiobooks()) r.bookKey,
      },
      // 纯字幕书（standalone SRT）身份 = uid。**只收 bookKey 为空的行**：与
      // [SrtBookRepository.delete] 的写墓碑判据同源——srt-backed 行的身份是 bookKey，
      // 已由上面的 book 键覆盖，重复收进来会让同一资产在对端弹两条确认（TODO-2470）。
      SyncTombstoneKind.srtbook.dbValue: <String>{
        for (final SrtBookRow r in await _db.getAllSrtBooks())
          if (r.bookKey.isEmpty) r.uid,
      },
      SyncTombstoneKind.video.dbValue: <String>{
        for (final VideoBookRow r in await _db.allVideoBooks()) r.bookUid,
      },
      SyncTombstoneKind.localaudio.dbValue: <String>{
        for (final LocalAudioDbEntry e in localAudioEntries) e.displayName,
      },
      SyncTombstoneKind.favoriteword.dbValue: <String>{
        for (final FavoriteWordRow r in await _db.getAllFavoriteWords())
          HibikiDatabase.favoriteWordItemKey(
              r.expression, r.reading, r.sourceType),
      },
      // 收藏句无稳定 id，用内容键（[FavoriteSentenceRepository.itemKeyOf]）；与写墓碑点、
      // aggregate 去重键同源。
      SyncTombstoneKind.favoritesentence.dbValue: <String>{
        for (final FavoriteSentence s
            in await FavoriteSentenceRepository(_db).getAll())
          FavoriteSentenceRepository.itemKeyOf(s),
      },
    };
  }

  /// 删除墓碑同步（云后端通道，显式确认式删除传播 Phase C/D）。
  ///
  /// **发布**：把本机未发布墓碑（remotePublishedAt==0）写成远端 `__tombstones__/`
  /// 标记文件（[deletionTombstoneAssetName] / [deletionTombstoneJson]），并
  /// [markSyncDeletionPublished] 防每轮重发。
  ///
  /// **消费**：读命名空间下全部远端标记 → 与本地在库键求交（[computeDeletionPropagation]
  /// 的 deleteLocal 方向）→ 过因果基线守卫（marker.deletedAt > 本设备
  /// [getDeletionTombstonesBaselineMs]）→ 塞进 [SyncRunReport.deletionCandidates]，由
  /// UI 层弹逐条确认框（orchestrator 无 context，绝不在此直接删）。基线**不在此推进**——
  /// 否则 app 在弹框前被杀，用户永远看不到该删除；改由 UI 确认后推进
  /// （[setDeletionTombstonesBaselineMs]，见 [deletionTombstonesHighWaterMs]）。
  ///
  /// 不自动 GC 远端标记：本设备仍持有该资产且 deletedAt <= 基线时，无法区分「保留」与
  /// 「删后重加」，误删标记会破坏其它设备的删除传播——书/视频不自动重导入，标记长存只是
  /// 极小的存储/新设备重弹成本，GC 留待 Phase F。整段 try/catch，错误进 report.errors。
  Future<void> syncDeletionTombstones(SyncRunReport report) async {
    try {
      final String ns =
          await _backend.ensureNamespace(kSyncTombstonesNamespace);
      final SyncRepository repo = SyncRepository(_db);
      final int nextBaseline = DateTime.now().millisecondsSinceEpoch;

      // ── 发布：本机未发布墓碑 → 远端标记 ──
      final List<SyncDeletionTombstoneRow> localRows =
          await _db.getSyncDeletionTombstones();
      for (final SyncDeletionTombstoneRow row in localRows) {
        if (row.remotePublishedAt != 0) continue;
        await _backend.putJsonAsset(
          ns,
          deletionTombstoneAssetName(row.mediaType, row.itemKey),
          deletionTombstoneJson(row.mediaType, row.itemKey, row.deletedAt),
        );
        await _db.markSyncDeletionPublished(
            row.mediaType, row.itemKey, nextBaseline);
      }

      // ── 消费：读远端标记 → deleteLocal 候选（过基线守卫）──
      final Map<String, Set<String>> remoteTombstones = <String, Set<String>>{};
      final Map<String, int> remoteDeletedAt = <String, int>{};
      final List<AssetEntry> children = await _backend.listChildren(ns);
      for (final AssetEntry e in children) {
        if (e.isFolder) continue;
        Object? json;
        try {
          json = await _backend.getJsonAsset(e.id);
        } catch (err) {
          report.noteError('deletion tombstone "${e.name}" unreadable', err);
          continue;
        }
        final parsed = parseDeletionTombstoneJson(json);
        if (parsed == null) continue;
        remoteTombstones
            .putIfAbsent(parsed.mediaType, () => <String>{})
            .add(parsed.itemKey);
        final String k = '${parsed.mediaType}\u0000${parsed.itemKey}';
        // 同资产多标记取较新 deletedAt（理论上主键唯一，防御性取 max）。
        final int? prev = remoteDeletedAt[k];
        if (prev == null || parsed.deletedAt > prev) {
          remoteDeletedAt[k] = parsed.deletedAt;
        }
      }

      final Map<String, Set<String>> present =
          await _collectPresentDeletionKeys();
      int baseline = await repo.getDeletionTombstonesBaselineMs();
      if (baseline > nextBaseline) baseline = nextBaseline; // 时钟回拨钳制。

      // deleteLocal 方向：远端有标记 ∧ 本地在库。localTombstones/remotePresent 传空
      // ⇒ 只产 deleteLocal，不产 deleteRemote（本设备的删除靠发布标记让对端各自消费）。
      final List<DeletionPropagationCandidate> raw = computeDeletionPropagation(
        localTombstones: const <String, Set<String>>{},
        remoteTombstones: remoteTombstones,
        localPresent: present,
        remotePresent: const <String, Set<String>>{},
      );
      for (final DeletionPropagationCandidate c in raw) {
        if (c.direction != DeletionPropagationDirection.deleteLocal) continue;
        final int? at = remoteDeletedAt['${c.mediaType}\u0000${c.itemKey}'];
        if (at == null || at <= baseline) continue; // 旧闻 / 已处理，不再弹。
        report.deletionCandidates.add(c);
        if (at > report.deletionTombstonesHighWaterMs) {
          report.deletionTombstonesHighWaterMs = at;
        }
      }
    } catch (e) {
      report.noteError('deletion tombstones sync', e);
    }
  }

  /// 删除墓碑同步（互联 host API 通道）。GET host 墓碑（老 host 404 → null 优雅跳过）→
  /// 与本地在库键求交 deleteLocal 候选 → 过基线守卫 → 塞 report。与云
  /// [syncDeletionTombstones] 同消费语义；互联为 GET-only（host→client 方向），client
  /// 自身删除不经此推给 host（各端自行确认删除，见蓝图）。
  Future<void> _syncDeletionTombstonesLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    try {
      final int nextBaseline = DateTime.now().millisecondsSinceEpoch;
      final List<({String mediaType, String itemKey, int deletedAt})>? remote =
          await backend.getRemoteDeletionTombstones();
      if (remote == null) return; // 老 host 无 /api/tombstones 端点，优雅跳过。

      final Map<String, Set<String>> remoteTombstones = <String, Set<String>>{};
      final Map<String, int> remoteDeletedAt = <String, int>{};
      for (final r in remote) {
        remoteTombstones
            .putIfAbsent(r.mediaType, () => <String>{})
            .add(r.itemKey);
        final String k = '${r.mediaType}\u0000${r.itemKey}';
        final int? prev = remoteDeletedAt[k];
        if (prev == null || r.deletedAt > prev) {
          remoteDeletedAt[k] = r.deletedAt;
        }
      }

      final SyncRepository repo = SyncRepository(_db);
      final Map<String, Set<String>> present =
          await _collectPresentDeletionKeys();
      int baseline = await repo.getDeletionTombstonesBaselineMs();
      if (baseline > nextBaseline) baseline = nextBaseline;

      final List<DeletionPropagationCandidate> raw = computeDeletionPropagation(
        localTombstones: const <String, Set<String>>{},
        remoteTombstones: remoteTombstones,
        localPresent: present,
        remotePresent: const <String, Set<String>>{},
      );
      for (final DeletionPropagationCandidate c in raw) {
        if (c.direction != DeletionPropagationDirection.deleteLocal) continue;
        final int? at = remoteDeletedAt['${c.mediaType}\u0000${c.itemKey}'];
        if (at == null || at <= baseline) continue;
        report.deletionCandidates.add(c);
        if (at > report.deletionTombstonesHighWaterMs) {
          report.deletionTombstonesHighWaterMs = at;
        }
      }
    } catch (e) {
      report.noteError('deletion tombstones live sync', e);
    }
  }

  /// 测试入口：直接调用 [_syncDeletionTombstonesLive]（private 对测试不可见）。
  @visibleForTesting
  Future<void> syncDeletionTombstonesLiveForTest(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) =>
      _syncDeletionTombstonesLive(report, backend);

  /// 云视频资产同步（多端库联合视图 §2.6 / 任务12，云后端通道）。
  ///
  /// 仅云后端 + `sync_video_files` 开启时由 [run] 调用。把本地 `VideoBooks` 里的
  /// **本地单文件**视频（流媒体 URL / 多集播放列表跳过——它们没有可上传的单个本地
  /// 字节，见 [_isUploadableLocalVideo]）推到 sync 根 `__videos__/` 命名空间：
  /// - 资产名按 bookUid 安全编码 + 原扩展名（[videoAssetName]）；
  /// - 远端已存在**同尺寸**跳过（upload-only，删除不传播——远端不删本地、本地删除
  ///   也不删远端，与书内容 [_syncBooksContentLive] / 有声书包同律）；
  /// - 封面（若有本地文件）作独立资产一并上传（[videoCoverAssetName]）。
  ///
  /// 同时维护 `__videos__/videos.json` 目录清单（[RemoteVideoManifest]）：读远端清单
  /// → 合本地在库视频条目（本地覆盖同 uid，远端独有 uid 保留——知识的并集）→ 字节
  /// 有变才回写（确定性排序 ⇒ 内容相等即字节相等，避免每轮写放大）。供其它端渲染
  /// 云视频占位卡 + 按 uid 下载（[CloudRemoteVideoClient]）。
  ///
  /// 整段 try/catch，逐项 + 整体错误进 [report.errors] 不中断整体 sweep（与其它维度
  /// 同纪律）。删除不跨端传播；[report.videosExported] 计上传数（跳过不计）。
  Future<void> syncVideoAssets(SyncRunReport report) async {
    try {
      final String ns = await _backend.ensureNamespace(kSyncVideosNamespace);

      // 远端既有资产（名 -> 大小），用于「同尺寸跳过」与「封面是否已上传」判定。
      final Map<String, int?> remoteSizeByName = <String, int?>{
        for (final AssetEntry e in await _backend.listChildren(ns))
          if (!e.isFolder) e.name: e.sizeBytes,
      };

      // 远端既有清单（无则空，首轮优雅退化为「只上传本机视频」）。
      final AssetEntry? manifestAsset =
          await _backend.findAsset(ns, kSyncVideosManifestName);
      RemoteVideoManifest remote = RemoteVideoManifest.empty;
      String? remoteCanonical;
      if (manifestAsset != null) {
        final Object? json = await _backend.getJsonAsset(manifestAsset.id);
        if (json == null) {
          // 清单资产存在但读不出（getJsonAsset 返 null = 下载失败/损坏）：本轮**跳过
          // 视频上传 + 清单回写**并 return（finding 3）。若照传：远端 = 空清单 →
          // priorEntry 恒 null → 每个视频每轮都判「远端无同尺寸」全量重传（无幂等判据的
          // 死循环，视频体积大代价惨重）；若回写：空清单覆盖抹掉他端全部条目。无法判幂等
          // 就不传，下轮下载成功即自愈。
          report.errors.add('video manifest present but unreadable; skipping '
              'video upload + manifest writeback this run (retried next run)');
          return;
        }
        remote = RemoteVideoManifest.fromJson(json);
        remoteCanonical = remote.canonicalJson();
      }

      // 合并清单起点 = 远端既有条目（按 uid 索引；本地在库的 uid 下面覆盖，远端独有
      // 的 uid 原样保留——upload-only 并集，绝不因本地缺这条而从清单里抹掉它）。
      final Map<String, RemoteVideoManifestEntry> byUid =
          <String, RemoteVideoManifestEntry>{
        for (final RemoteVideoManifestEntry e in remote.videos) e.uid: e,
      };

      // 稳定顺序（uid 升序）遍历本地可上传视频，进度分母 = 可上传视频数。
      final List<VideoBookRow> localVideos = <VideoBookRow>[
        for (final VideoBookRow v in await _db.allVideoBooks())
          if (_isUploadableLocalVideo(v)) v,
      ]..sort(
          (VideoBookRow a, VideoBookRow b) => a.bookUid.compareTo(b.bookUid));
      final int total = localVideos.length;
      int index = 0;

      for (final VideoBookRow v in localVideos) {
        _emit(SyncPhase.videos,
            itemIndex: index, itemTotal: total, title: v.title);
        try {
          final File file = File(v.videoPath);
          if (!file.existsSync()) {
            report.errors
                .add('video "${v.title}": local file missing: ${v.videoPath}');
            index++;
            continue;
          }
          final int size = await file.length();
          final String assetName = videoAssetName(v.bookUid, v.videoPath);

          // 封面（可选、独立资产）：本地有文件且远端尚无同名资产才上传。
          String? coverAsset;
          final String? coverPath = v.coverPath;
          if (coverPath != null &&
              coverPath.isNotEmpty &&
              File(coverPath).existsSync()) {
            coverAsset = videoCoverAssetName(v.bookUid, coverPath);
            if (!remoteSizeByName.containsKey(coverAsset)) {
              await _backend.putAsset(ns, coverAsset, File(coverPath));
              remoteSizeByName[coverAsset] = await File(coverPath).length();
            }
          }

          // 视频文件：远端已存在同尺寸跳过（upload-only 幂等）。跳过判据**不能**用
          // 远端资产的物理尺寸——`resolveSyncBackend` 无条件包 ObfuscatingSyncBackend，
          // 上传体 = 8 字节 magic + XOR 正文（远端尺寸 = 明文 + 8，永不等于本地明文
          // size），且 Dropbox/WebDAV/FTP 的 listChildren 根本不报 sizeBytes（null）。
          // 改用清单记录的**明文尺寸**（跨后端可靠）：远端按名存在 && 合并清单里该 uid
          // 条目 videoAsset 同名 && 记录的明文尺寸 == 本地明文尺寸 ⇒ 跳过。
          final RemoteVideoManifestEntry? priorEntry = byUid[v.bookUid];
          final bool remoteHasByName = remoteSizeByName.containsKey(assetName);
          final bool manifestSameSize = priorEntry != null &&
              priorEntry.videoAsset == assetName &&
              priorEntry.sizeBytes == size;
          if (!(remoteHasByName && manifestSameSize)) {
            await _backend.putAsset(ns, assetName, file,
                onProgress: (double f) => _emit(SyncPhase.videos,
                    itemIndex: index,
                    itemTotal: total,
                    title: v.title,
                    fileFraction: f));
            remoteSizeByName[assetName] = size;
            report.videosExported++;
          }

          // tags 稳健档：清单条目累积「知识的并集」——本地标签 LWW 时钟与 priorEntry
          // （他端已发布）取 max 并集，使单一共享清单文件不因后写覆盖丢掉他端标签知识；
          // 下载端按 max(add) vs max(removed) 逐名解析。删除靠墓碑跨端传播、防复活。
          final Map<String, int> mergedTagAddedAt = _unionMaxIntMap(
            await _db.videoTagAddedAtByName(v.bookUid),
            priorEntry?.tagsAddedAt ?? const <String, int>{},
          );
          final Map<String, int> mergedTagTombstones = _unionMaxIntMap(
            await _db.tagTombstonesByName(v.bookUid, MediaKind.video),
            priorEntry?.tagTombstones ?? const <String, int>{},
          );

          // 无论是否跳过上传，都刷新清单条目（保证同尺寸跳过时清单仍有此 uid）。
          // coverAsset 回退保留 byUid 既有值：本地封面文件丢失 ≠ 远端没有封面，绝不
          // 把已发布的 coverAsset 抹成 null。
          byUid[v.bookUid] = RemoteVideoManifestEntry(
            uid: v.bookUid,
            title: v.title,
            videoAsset: assetName,
            sizeBytes: size,
            importedAtMs: v.importedAt ?? 0,
            coverAsset: coverAsset ?? priorEntry?.coverAsset,
            tagsAddedAt: mergedTagAddedAt,
            tagTombstones: mergedTagTombstones,
          );
        } catch (e) {
          report.noteError('video "${v.title}"', e);
        }
        index++;
      }

      // 回写门槛：字节有变才写；远端本无清单且合并结果为空（零视频库）不无中生有
      // 地创建空文件。（清单损坏已在上方 return，走不到这里。）
      final RemoteVideoManifest merged = RemoteVideoManifest(
        videos: byUid.values.toList(),
      );
      final bool nothingToPublish =
          manifestAsset == null && merged.videos.isEmpty;
      if (!nothingToPublish && merged.canonicalJson() != remoteCanonical) {
        await _backend.putJsonAsset(
            ns, kSyncVideosManifestName, merged.toJson());
      }
    } catch (e) {
      report.noteError('video assets sync', e);
    }
  }

  /// 一条 `VideoBooks` 行是否是可作为单文件上传的**本地**视频（[syncVideoAssets] 用）。
  ///
  /// 排除：流媒体（`streamSpecJson` 非空 / `videoPath` 为 http(s) URL）——无本地字节
  /// 可传；多集播放列表（`playlistJson` 非空）——单文件资产模型装不下多集（多集上传
  /// 是后续批的接缝，见 §2.6 seam）。
  bool _isUploadableLocalVideo(VideoBookRow v) {
    if (v.streamSpecJson != null) return false;
    if (v.playlistJson != null) return false;
    final String path = v.videoPath;
    if (path.isEmpty) return false;
    final String lower = path.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return false;
    }
    return true;
  }

  /// Folds the per-book sweep results into [SyncRunReport.conflicts]. Only
  /// [SyncResult.conflict] rows are collected; everything else (imported /
  /// exported / synced / skipped) is left to the existing per-phase tallies
  /// and is NOT counted here. A conflict carries the four fields filled by
  /// [SyncManager] when it detects a genuine three-way fork.
  void _collectConflicts(
    List<SyncBookResult> results,
    SyncRunReport report,
  ) {
    for (final SyncBookResult result in results) {
      if (result.direction != SyncResult.conflict) continue;
      report.conflicts.add(SyncConflict(
        assetKey: result.conflictAssetKey!,
        dimension: result.conflictDimension!,
        title: result.title,
        localVersion: result.conflictLocalVersion,
        remoteVersion: result.conflictRemoteVersion,
      ));
    }
  }

  /// Imports remote-only books for explicit/manual download flows.
  ///
  /// Automatic sync deliberately does not call this method: the
  /// `syncContent` setting is "upload book files", not "pull remote-only
  /// books". Remote folders still need a `.epub` content asset; folders
  /// without one are skipped.
  Future<void> importRemoteBooks(String root, SyncRunReport report) async {
    final List<SyncFileRef> remoteFolders = await _backend.listBooks(root);
    final Set<String> localKeys = <String>{
      for (final EpubBookRow b in await _db.getAllEpubBooks())
        sanitizeTtuFilename(b.title),
    };

    // Resolve the remote-only set first so progress has a real denominator.
    final List<SyncFileRef> toImport = <SyncFileRef>[
      for (final SyncFileRef folder in remoteFolders)
        if (!isReservedSyncFolderName(folder.name) &&
            !isReservedSyncFolderName(sanitizeTtuFilename(folder.name)) &&
            !localKeys.contains(sanitizeTtuFilename(folder.name)))
          folder,
    ];
    final int total = toImport.length;

    for (int i = 0; i < total; i++) {
      final SyncFileRef folder = toImport[i];
      _emit(SyncPhase.books,
          itemIndex: i, itemTotal: total, title: folder.name);
      try {
        if (await importRemoteBookFolder(
          db: _db,
          backend: _backend,
          folderId: folder.id,
          tempDir: _tempDir,
          // 下载远端书文件夹时一并补下其有声书包（修复云有声书「只上传拿不回」缺口）。
          audioDatabaseRoot: _audioDatabaseRoot,
          onProgress: (double f) => _emit(SyncPhase.books,
              itemIndex: i,
              itemTotal: total,
              title: folder.name,
              fileFraction: f),
        )) {
          report.booksImported++;
        }
      } catch (e) {
        report.noteError('import book "${folder.name}"', e);
      }
    }
  }

  /// 互联书籍内容 live 上传。
  ///
  /// 直打对端 `/api/library/books` 端点，按 `sanitizeTtuFilename(title)` 只处理
  /// toPush：本端有 && 远端无 → `repackageExtractedEpub` 重打包 →
  /// `putRemoteBook` 上传。远端独有书籍留给 compare/interconnect UI 手动下载。
  ///
  /// 仅当 client syncContent 开时由 [run] 调用。进度走 [SyncPhase.books]，
  /// 临时文件 finally 清理，逐项错误进 [report.errors] 不中断整体。
  ///
  /// **删除传播**：现有实现不传播书籍删除（SyncManager 云路径同语义）。
  /// 若后续需要互联书籍删除传播，参考词典删除传播（BUG-086）扩展此方法。
  Future<void> _syncBooksContentLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    final List<RemoteBookInfo> remoteBooks = await backend.listRemoteBooks();
    final List<EpubBookRow> localBooks = await _db.getAllEpubBooks();

    final Set<String> localKeys = <String>{
      for (final EpubBookRow b in localBooks) sanitizeTtuFilename(b.title),
    };
    final Map<String, bool> remoteKeyHasContent = <String, bool>{
      for (final RemoteBookInfo r in remoteBooks)
        sanitizeTtuFilename(r.title): r.hasContent,
    };

    // 按 sanitizeTtuFilename(title) union 计算 diff。
    final BookSyncDiff diff = computeBookSyncDiff(
      localKeys: localKeys,
      remoteKeyHasContent: remoteKeyHasContent,
    );

    // 需要本地 title 原始值用于端点调用（端点按原始 title 寻址）。
    final Map<String, String> localKeyToTitle = <String, String>{
      for (final EpubBookRow b in localBooks)
        sanitizeTtuFilename(b.title): b.title,
    };

    final int total = diff.toPush.length;
    int index = 0;

    // ── Push：本端独有 → 重打包并上传 ───────────────────────────────────────
    for (final String key in diff.toPush) {
      final String title = localKeyToTitle[key] ?? key;
      _emit(SyncPhase.books, itemIndex: index, itemTotal: total, title: title);
      File? tmp;
      try {
        // 找到本地行取 extractDir。
        final EpubBookRow? row = localBooks.cast<EpubBookRow?>().firstWhere(
              (EpubBookRow? b) => sanitizeTtuFilename(b!.title) == key,
              orElse: () => null,
            );
        if (row == null ||
            row.extractDir.isEmpty ||
            !Directory(row.extractDir).existsSync()) {
          // 本地内容不可用，跳过（与 importRemoteBooks 对称语义）。
          report.errors
              .add('live push book "$title": extractDir missing or empty');
          index++;
          continue;
        }
        tmp = _tmpFile('.epub');
        final bool built =
            await repackageExtractedEpub(row.extractDir, tmp.path);
        if (!built) {
          report.errors
              .add('live push book "$title": repackage produced no epub');
          index++;
          continue;
        }
        await backend.putRemoteBook(
          title,
          tmp,
          onProgress: (double f) => _emit(SyncPhase.books,
              itemIndex: index,
              itemTotal: total,
              title: title,
              fileFraction: f),
        );
      } catch (e) {
        report.noteError('live push book "$title"', e);
      } finally {
        _safeDelete(tmp);
      }
      index++;
    }
  }

  /// 互联书籍阅读进度 live 双向同步（TODO-767）。
  ///
  /// 遍历本地 `epub_books`，对每本书：GET host 真相源进度（[RemoteBookClient
  /// .remoteBookProgress]，host 直读自己的 `reader_positions`）+ 读本地
  /// `reader_positions`，用 [resolveBookProgressSync]「取较新时间戳」选胜者；胜者
  /// 严格新于 host 时 PUT 上报 host（[RemoteBookClient.putRemoteBookProgress]，host
  /// 再防御性取较新落自己的 DB），胜者不同于本地时 upsert 回本地。
  ///
  /// 修复根因：互联「立即同步」此前书籍进度只走 SyncManager 的 WebDAV 文件箱
  /// （progress_*.json），host 从不读回自己的 reader_positions DB，故进度不过去。
  /// 这里补对称视频 TODO-653 的 live 端点 + host-apply，让进度真正落 host DB。
  ///
  /// 逐本错误进 [report.errors] 不中断整体。
  Future<void> _syncBookProgressLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    final List<EpubBookRow> localBooks = await _db.getAllEpubBooks();
    for (final EpubBookRow book in localBooks) {
      try {
        final RemoteBookProgress remote =
            await backend.remoteBookProgress(book.bookKey);
        final ReaderPositionRow? localRow =
            await _db.getReaderPosition(book.bookKey);
        final RemoteBookProgress local = localRow == null
            ? RemoteBookProgress.empty
            : RemoteBookProgress(
                sectionIndex: localRow.sectionIndex,
                normCharOffset: localRow.normCharOffset,
                charOffset: localRow.charOffset,
                updatedAtMs: localRow.updatedAt,
              );
        final RemoteBookProgress winner =
            resolveBookProgressSync(local: local, remote: remote);

        // 本地→host：胜者严格新于 host 时上报（host 端再取较新，幂等安全）。
        if (winner.updatedAtMs > remote.updatedAtMs ||
            (winner.updatedAtMs == remote.updatedAtMs &&
                (winner.sectionIndex != remote.sectionIndex ||
                    winner.normCharOffset != remote.normCharOffset ||
                    winner.charOffset != remote.charOffset))) {
          await backend.putRemoteBookProgress(book.bookKey, winner);
        }

        // host→本地：胜者不同于本地时 upsert 回本地 reader_positions。
        final bool localChanged = winner.sectionIndex != local.sectionIndex ||
            winner.normCharOffset != local.normCharOffset ||
            winner.charOffset != local.charOffset ||
            winner.updatedAtMs != local.updatedAtMs;
        if (localChanged && winner.updatedAtMs > 0) {
          await _db.upsertReaderPosition(ReaderPositionsCompanion(
            bookKey: Value(book.bookKey),
            sectionIndex: Value(winner.sectionIndex),
            normCharOffset: Value(winner.normCharOffset),
            charOffset: Value(winner.charOffset),
            updatedAt: Value(winner.updatedAtMs),
          ));
          // BUG-686: a host-newer progress pull lands in reader_positions but
          // writes no book content, so it must still flag the shelf for a
          // refresh — the cached hibikiBooksProvider otherwise keeps showing the
          // pre-sync progress bar and the sync looks like it did nothing.
          report.localBookProgressPulled++;
        }
      } catch (e) {
        report.noteError('live book progress "${book.title}"', e);
      }
    }
  }

  /// 互联播放断点 live 双向 sweep 的共享模板（视频 / 有声书）。
  ///
  /// 两条 sweep 历史上 ~90% 逐字同构，仅四个探针不同，命名统一轮收口于此。
  /// 对 [localKeys] ∩ [hostKeys] 里的每个键：
  /// 1. [readLocal] 取本地 (位置, 时间戳)，[readHost] 取 host (位置, 时间戳)；
  /// 2. [resolvePositionLww]「取较新时间戳」选胜者；
  /// 3. 本地→host：胜者新于 host（或同戳不同位）→ [pushToHost] 上报
  ///    （host 端再取较新，幂等安全）；
  /// 4. host→本地：胜者不同于本地 → [writeBackLocal] 写回。
  ///
  /// 只对 host 也有的键同步（本地独有条目无 host 真相，跳过）；逐条错误以
  /// `[errorLabel] "<key>": <e>` 进 [report.errors] 不中断整体。host 清单的获取
  /// 与两侧空集合的早退仍在各调用方（保持既有网络行为不变）。
  Future<void> _syncPositionsLive(
    SyncRunReport report, {
    required String errorLabel,
    required Set<String> localKeys,
    required Set<String> hostKeys,
    required Future<({int positionMs, int updatedAtMs})> Function(String key)
        readLocal,
    required Future<({int positionMs, int updatedAtMs})> Function(String key)
        readHost,
    required Future<void> Function(String key, int positionMs, int updatedAtMs)
        pushToHost,
    required Future<void> Function(String key, int positionMs, int updatedAtMs)
        writeBackLocal,
  }) async {
    for (final String key in localKeys) {
      if (!hostKeys.contains(key)) continue; // host 无此条目：跳过。
      try {
        final ({int positionMs, int updatedAtMs}) local = await readLocal(key);
        final ({int positionMs, int updatedAtMs}) host = await readHost(key);

        final ({int positionMs, int updatedAtMs}) winner = resolvePositionLww(
          localPositionMs: local.positionMs,
          localUpdatedAtMs: local.updatedAtMs,
          remotePositionMs: host.positionMs,
          remoteUpdatedAtMs: host.updatedAtMs,
        );

        // 本地→host：胜者新于 host 时上报（host 端再取较新，幂等安全）。
        if (winner.updatedAtMs > host.updatedAtMs ||
            (winner.updatedAtMs == host.updatedAtMs &&
                winner.positionMs != host.positionMs)) {
          await pushToHost(key, winner.positionMs, winner.updatedAtMs);
        }

        // host→本地：胜者不同于本地时写回。
        if (winner.positionMs != local.positionMs ||
            winner.updatedAtMs != local.updatedAtMs) {
          await writeBackLocal(key, winner.positionMs, winner.updatedAtMs);
        }
      } catch (e) {
        report.noteError('$errorLabel "$key"', e);
      }
    }
  }

  /// 互联视频播放进度 live 双向同步（TODO-767 + TODO-816）。
  ///
  /// 此前只遍历本地 `VideoBooks`，对每条比对 host 进度。但 client 流式看的远端视频
  /// 在本地**没有 VideoBooks 行**（[home_video_page._openRemote] 只 push 不 upsert，
  /// 进度只落 `video_remote_position_<uid>` prefs，见 video_hibiki_page._persistRemotePosition）
  /// → 旧 sweep 永远扫不到，流式视频进度无法纳入全量双向同步（TODO-816 子问题1 断点①）。
  ///
  /// 修复：同步基底统一为 uid 集合 = 「本地 VideoBooks 行 uid」∪「本地有
  /// `video_remote_position_<uid>` prefs 的 uid（哪怕无行）」，只对 host 也有的 uid 同步。
  ///
  /// 本地进度真相：书架视频与流式视频共用一个 `_at_` prefs 时间戳。书架视频的位置
  /// 在 `VideoBooks.lastPositionMs`（本机播放写），流式视频的位置在
  /// `video_remote_position_<uid>` prefs（resume 路径写）——同一进度的两处镜像，不会
  /// 同时各有不同含义。本地位置取「有行用 lastPositionMs，否则用 prefs 位置」，时间戳
  /// 统一取 `_at_` prefs（无则 0=旧数据，被任何带时间戳的远端进度盖过）。
  ///
  /// 写回时位置真相统一落 `video_remote_position_<uid>` + `_at_` prefs（resume 路径
  /// 同键空间）；**仅当本地存在 VideoBooks 行时**才一并更新 `lastPositionMs`
  /// （流式视频绝不强建行污染书架）。
  ///
  /// LWW 比对与逐条错误处理见共享模板 [_syncPositionsLive]。
  Future<void> _syncVideoProgressLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    // 基底①：本地 VideoBooks 行（uid → lastPositionMs，向后兼容书架视频）。
    final Map<String, int> rowPositionByUid = <String, int>{};
    for (final VideoBookRow video in await _db.allVideoBooks()) {
      rowPositionByUid[video.bookUid] = video.lastPositionMs;
    }
    // 基底②：本地看过的流式视频（有 video_remote_position_<uid> prefs 但无行）。
    final Set<String> localUids = <String>{...rowPositionByUid.keys};
    final Map<String, String> allPrefs = await _db.getAllPrefs();
    for (final String key in allPrefs.keys) {
      final String? uid = videoUidFromRemotePositionPrefKey(key);
      if (uid != null) localUids.add(uid);
    }
    if (localUids.isEmpty) return;

    // 视频进度是 host-truth 模型：进度端点只对 host DB 里真实存在的视频可用。先取
    // host 视频清单（条目已带 positionMs / positionUpdatedAtMs，省去逐视频 GET），
    // 只对两端都有的视频同步；本地独有视频（host 无）无 host 真相可同步，跳过。
    final Map<String, RemoteVideoInfo> hostById = <String, RemoteVideoInfo>{};
    for (final RemoteVideoInfo info in await backend.listRemoteVideos()) {
      hostById[info.id] = info;
    }
    if (hostById.isEmpty) return;

    await _syncPositionsLive(
      report,
      errorLabel: 'live video progress',
      localKeys: localUids,
      hostKeys: hostById.keys.toSet(),
      readLocal: (String uid) async {
        final int prefsPos =
            await _db.getPrefTyped<int>(videoRemotePositionPrefKey(uid), 0);
        final int prefsAt =
            await _db.getPrefTyped<int>(videoRemotePositionAtPrefKey(uid), 0);
        return (
          positionMs: rowPositionByUid[uid] ?? prefsPos,
          updatedAtMs: prefsAt,
        );
      },
      // host 清单条目已带 positionMs / positionUpdatedAtMs，无需逐视频 GET。
      readHost: (String uid) async {
        final RemoteVideoInfo info = hostById[uid]!;
        return (
          positionMs: info.positionMs,
          updatedAtMs: info.positionUpdatedAtMs,
        );
      },
      pushToHost: (String uid, int positionMs, int updatedAtMs) =>
          backend.putRemoteVideoPosition(uid, positionMs, updatedAtMs),
      writeBackLocal: (String uid, int positionMs, int updatedAtMs) async {
        await _db.setPrefTyped<int>(
            videoRemotePositionPrefKey(uid), positionMs);
        await _db.setPrefTyped<int>(
            videoRemotePositionAtPrefKey(uid), updatedAtMs);
        if (rowPositionByUid.containsKey(uid)) {
          await _db.updateVideoBookPosition(uid, positionMs);
        }
      },
    );
  }

  /// 互联有声书播放进度 live 双向同步（BUG-471）。
  ///
  /// 与视频 [_syncVideoProgressLive] 完全对称（共享模板 [_syncPositionsLive]）。
  /// client 听的远端有声书进度落 `audiobook_pos_<bookKey>` +
  /// `audiobook_pos_at_<bookKey>` prefs（见 [AudiobookRepository.updatePositionMs]），
  /// 但互联角色非对称：host 只跑 server，从不回灌自己的 `audiobook_pos_` pref，
  /// 故「立即同步」点了进度不过去（云后端经 SyncManager 双向文件箱正常，互联缺这一段）。
  ///
  /// 同步基底 = 「本地有 `audiobook_pos_<key>` prefs 的 bookKey」∪「本地 Audiobooks
  /// 行的 bookKey」，只对 host 也有的 bookKey 同步（host 无该有声书时其 PUT 端点
  /// 404 / 闸门 no-op，且 GET 无真相可拉，跳过省一次网络）。本地进度真相 =
  /// `audiobook_pos_<bookKey>`（位置）+ `audiobook_pos_at_<bookKey>`（时间戳，
  /// 旧数据无记 0）；写回落同一 prefs 键空间（同 resume/播放写）。
  Future<void> _syncAudiobookProgressLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    // 同步基底：本地 Audiobooks 行 ∪ 本地有 audiobook_pos_<key> prefs 的 bookKey。
    final Set<String> localKeys = <String>{
      for (final AudiobookRow ab in await _db.getAllAudiobooks()) ab.bookKey,
    };
    final Map<String, String> allPrefs = await _db.getAllPrefs();
    for (final String key in allPrefs.keys) {
      final String? bookKey = audiobookKeyFromPositionPrefKey(key);
      if (bookKey != null) localKeys.add(bookKey);
    }
    if (localKeys.isEmpty) return;

    // 有声书进度是 host-truth 模型：只对 host 也有的有声书同步。先取 host 有声书
    // 清单，只同步两端都有的 bookKey；本地独有有声书无 host 真相，跳过。
    final Set<String> hostKeys = <String>{
      for (final RemoteAudiobookInfo info
          in await backend.listRemoteAudiobooks())
        info.bookKey,
    };
    if (hostKeys.isEmpty) return;

    await _syncPositionsLive(
      report,
      errorLabel: 'live audiobook progress',
      localKeys: localKeys,
      hostKeys: hostKeys,
      readLocal: (String bookKey) async => (
        positionMs:
            await _db.getPrefTyped<int>(audiobookPositionPrefKey(bookKey), 0),
        updatedAtMs:
            await _db.getPrefTyped<int>(audiobookPositionAtPrefKey(bookKey), 0),
      ),
      readHost: (String bookKey) => backend.remoteAudiobookPosition(bookKey),
      pushToHost: (String bookKey, int positionMs, int updatedAtMs) =>
          backend.putRemoteAudiobookPosition(bookKey, positionMs, updatedAtMs),
      writeBackLocal: (String bookKey, int positionMs, int updatedAtMs) async {
        await _db.setPrefTyped<int>(
            audiobookPositionPrefKey(bookKey), positionMs);
        await _db.setPrefTyped<int>(
            audiobookPositionAtPrefKey(bookKey), updatedAtMs);
      },
    );
  }

  /// 测试入口：直接调用 [_syncBookProgressLive]。
  @visibleForTesting
  Future<void> syncBookProgressLiveForTest(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) =>
      _syncBookProgressLive(report, backend);

  /// 测试入口：直接调用 [_syncVideoProgressLive]。
  @visibleForTesting
  Future<void> syncVideoProgressLiveForTest(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) =>
      _syncVideoProgressLive(report, backend);

  /// 测试入口：直接调用 [_syncAudiobookProgressLive]。
  @visibleForTesting
  Future<void> syncAudiobookProgressLiveForTest(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) =>
      _syncAudiobookProgressLive(report, backend);

  /// 测试入口：直接调用 [_syncBooksContentLive]（private 方法对测试文件不可见）。
  @visibleForTesting
  Future<void> syncBooksContentLiveForTest(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) =>
      _syncBooksContentLive(report, backend);

  /// 测试入口：直接调用 [_syncLocalAudioLive]。
  @visibleForTesting
  Future<void> syncLocalAudioLiveForTest(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) =>
      _syncLocalAudioLive(report, backend);

  /// 测试入口：直接调用 [_syncAudiobooksLive]。
  @visibleForTesting
  Future<void> syncAudiobooksLiveForTest(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) =>
      _syncAudiobooksLive(report, backend);

  /// Union-syncs dictionaries. 互联（InterconnectSyncBackend）→ 直读对端实时库（无暂存）；
  /// 云后端 → 走现有 __dictionaries__ 暂存路径（不变）。无旧设备故无能力探测。
  Future<void> syncDictionaries(SyncRunReport report) async {
    final SyncBackend b = _backend;
    if (b is InterconnectSyncBackend) {
      await _syncDictionariesLive(report, b);
      return;
    }
    await _syncDictionariesStaged(report);
  }

  /// 互联直读对端实时词典：按名 union，绝不创建/读写 __dictionaries__。
  Future<void> _syncDictionariesLive(
      SyncRunReport report, InterconnectSyncBackend backend) async {
    final List<DictionaryMetaRow> localDicts =
        await _db.getAllDictionaryMetadata();
    final List<RemoteDictionaryInfo> remoteDicts =
        await backend.listRemoteDictionaries();

    final SyncKeyDiff diff = computeKeyUnionDiff(
      localKeys: <String>{for (final DictionaryMetaRow d in localDicts) d.name},
      remoteKeys: <String>{
        for (final RemoteDictionaryInfo d in remoteDicts) d.name
      },
    );

    final int total = diff.toPull.length + diff.toPush.length;
    int index = 0;

    for (final String name in diff.toPull) {
      _emit(SyncPhase.dictionaries,
          itemIndex: index, itemTotal: total, title: name);
      File? tmp;
      try {
        tmp = _tmpFile(_dictionaryAssetSuffix);
        await backend.getRemoteDictionary(name, tmp,
            onProgress: (double f) => _emit(SyncPhase.dictionaries,
                itemIndex: index,
                itemTotal: total,
                title: name,
                fileFraction: f));
        await _packages.importDictionaryPackage(
          packageFile: tmp,
          dictionaryResourceRoot: _dictionaryResourceRoot,
        );
        report.dictionariesImported++;
      } catch (e) {
        report.noteError('pull dictionary "$name"', e);
      } finally {
        _safeDelete(tmp);
      }
      index++;
    }

    for (final String name in diff.toPush) {
      _emit(SyncPhase.dictionaries,
          itemIndex: index, itemTotal: total, title: name);
      File? tmp;
      try {
        tmp = _tmpFile(_dictionaryAssetSuffix);
        await _packages.exportDictionaryPackage(
          dictionaryName: name,
          dictionaryResourceRoot: _dictionaryResourceRoot,
          outputFile: tmp,
        );
        await backend.putRemoteDictionary(name, tmp,
            onProgress: (double f) => _emit(SyncPhase.dictionaries,
                itemIndex: index,
                itemTotal: total,
                title: name,
                fileFraction: f));
        report.dictionariesExported++;
      } catch (e) {
        report.noteError('push dictionary "$name"', e);
      } finally {
        _safeDelete(tmp);
      }
      index++;
    }
  }

  /// Union-syncs dictionary packages in the `__dictionaries__` namespace.
  Future<void> _syncDictionariesStaged(SyncRunReport report) async {
    final String ns = await _backend.ensureNamespace(kSyncDictionaryNamespace);
    final List<DictionaryMetaRow> localDicts =
        await _db.getAllDictionaryMetadata();
    final List<AssetEntry> remote = await _backend.listChildren(ns);

    final Set<String> remoteNames = <String>{
      for (final AssetEntry e in remote)
        if (!e.isFolder && e.name.endsWith(_dictionaryAssetSuffix))
          e.name.substring(0, e.name.length - _dictionaryAssetSuffix.length),
    };
    final Set<String> localNames = <String>{
      for (final DictionaryMetaRow d in localDicts) d.name,
    };

    // Resolve both sides' work first so progress has a real denominator.
    final List<DictionaryMetaRow> toPush = <DictionaryMetaRow>[
      for (final DictionaryMetaRow d in localDicts)
        if (!remoteNames.contains(d.name)) d,
    ];
    final List<AssetEntry> toPull = <AssetEntry>[
      for (final AssetEntry e in remote)
        if (!e.isFolder &&
            e.name.endsWith(_dictionaryAssetSuffix) &&
            !localNames.contains(e.name
                .substring(0, e.name.length - _dictionaryAssetSuffix.length)))
          e,
    ];
    final int total = toPush.length + toPull.length;
    int index = 0;

    // Push local-only dictionaries.
    for (final DictionaryMetaRow d in toPush) {
      _emit(SyncPhase.dictionaries,
          itemIndex: index, itemTotal: total, title: d.name);
      File? tmp;
      try {
        tmp = _tmpFile(_dictionaryAssetSuffix);
        await _packages.exportDictionaryPackage(
          dictionaryName: d.name,
          dictionaryResourceRoot: _dictionaryResourceRoot,
          outputFile: tmp,
        );
        await _backend.putAsset(ns, '${d.name}$_dictionaryAssetSuffix', tmp,
            onProgress: (double f) => _emit(SyncPhase.dictionaries,
                itemIndex: index,
                itemTotal: total,
                title: d.name,
                fileFraction: f));
        report.dictionariesExported++;
      } catch (e) {
        report.noteError('export dictionary "${d.name}"', e);
      } finally {
        _safeDelete(tmp);
      }
      index++;
    }

    // Pull remote-only dictionaries.
    for (final AssetEntry e in toPull) {
      // Show the clean dictionary name in progress, matching the push side —
      // the asset name still carries the `.hibikidict` suffix, which otherwise
      // surfaces as a "weird" entry in the progress list.
      final String displayName = e.name.endsWith(_dictionaryAssetSuffix)
          ? e.name.substring(0, e.name.length - _dictionaryAssetSuffix.length)
          : e.name;
      _emit(SyncPhase.dictionaries,
          itemIndex: index, itemTotal: total, title: displayName);
      File? tmp;
      try {
        tmp = _tmpFile(_dictionaryAssetSuffix);
        await _backend.getAsset(e.id, tmp,
            onProgress: (double f) => _emit(SyncPhase.dictionaries,
                itemIndex: index,
                itemTotal: total,
                title: displayName,
                fileFraction: f));
        await _packages.importDictionaryPackage(
          packageFile: tmp,
          dictionaryResourceRoot: _dictionaryResourceRoot,
        );
        report.dictionariesImported++;
      } catch (err) {
        report.noteError('import dictionary "${e.name}"', err);
      } finally {
        _safeDelete(tmp);
      }
      index++;
    }
  }

  /// 互联本地音频 live 同步（Phase 3 T3.4）。
  ///
  /// 直打对端 `/api/library/localaudio` 端点，按 `displayName` union：
  /// - toPull：远端有 ∧ 本端无 → `getRemoteLocalAudio` 下载包 → `onLocalAudioImported` 注册；
  /// - toPush：本端有 ∧ 远端无 → `exportLocalAudioPackage` 打包 → `putRemoteLocalAudio` 上传。
  ///
  /// 仅当 client syncLocalAudio 开且 isInterconnect 时由 [run] 调用。
  /// 进度走 [SyncPhase.localAudio]，临时文件 finally 清理，逐项错误进 report.errors 不中断。
  Future<void> _syncLocalAudioLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    final List<RemoteLocalAudioInfo> remoteEntries =
        await backend.listRemoteLocalAudio();
    final Set<String> localNames = <String>{
      for (final LocalAudioDbEntry d in localAudioEntries) d.displayName,
    };
    final Set<String> remoteNames = <String>{
      for (final RemoteLocalAudioInfo r in remoteEntries) r.displayName,
    };

    final SyncKeyDiff diff = computeKeyUnionDiff(
      localKeys: localNames,
      remoteKeys: remoteNames,
    );

    final int total = diff.toPull.length + diff.toPush.length;
    int index = 0;

    // ── Pull：远端独有 → 下载并注册 ────────────────────────────────────────
    for (final String name in diff.toPull) {
      _emit(SyncPhase.localAudio,
          itemIndex: index, itemTotal: total, title: name);
      File? tmp;
      File? stagingDb;
      try {
        tmp = _tmpFile(_localAudioAssetSuffix);
        await backend.getRemoteLocalAudio(
          name,
          tmp,
          onProgress: (double f) => _emit(SyncPhase.localAudio,
              itemIndex: index, itemTotal: total, title: name, fileFraction: f),
        );
        final LocalAudioPackageContents contents =
            await _packages.importLocalAudioPackage(
          packageFile: tmp,
          stagingDir: _tempDir,
        );
        stagingDb = contents.dbFile;
        if (onLocalAudioImported != null) {
          await onLocalAudioImported!(contents);
          report.localAudioImported++;
        }
      } catch (e) {
        report.noteError('live pull local audio "$name"', e);
      } finally {
        _safeDelete(tmp);
        _safeDelete(stagingDb);
      }
      index++;
    }

    // ── Push：本端独有 → 打包并上传 ─────────────────────────────────────────
    for (final String name in diff.toPush) {
      _emit(SyncPhase.localAudio,
          itemIndex: index, itemTotal: total, title: name);
      File? tmp;
      try {
        final LocalAudioDbEntry? entry =
            localAudioEntries.cast<LocalAudioDbEntry?>().firstWhere(
                  (LocalAudioDbEntry? d) => d!.displayName == name,
                  orElse: () => null,
                );
        if (entry == null || !File(entry.path).existsSync()) {
          report.errors.add(
              'live push local audio "$name": DB file missing or not found');
          index++;
          continue;
        }
        tmp = _tmpFile(_localAudioAssetSuffix);
        await _packages.exportLocalAudioPackage(
          displayName: entry.displayName,
          enabled: entry.enabled,
          sources: entry.sources,
          dbFile: File(entry.path),
          outputFile: tmp,
        );
        await backend.putRemoteLocalAudio(
          name,
          tmp,
          onProgress: (double f) => _emit(SyncPhase.localAudio,
              itemIndex: index, itemTotal: total, title: name, fileFraction: f),
        );
        report.localAudioExported++;
      } catch (e) {
        report.noteError('live push local audio "$name"', e);
      } finally {
        _safeDelete(tmp);
      }
      index++;
    }
  }

  /// 互联有声书包 live 双向同步（TODO-809：立即/自动同步双向拉取）。
  ///
  /// 直打对端 `/api/library/audiobooks` 端点，按 `bookKey` union：
  /// - Push（本端有 ∧ 远端无）→ `exportAudioDatabasePackage` 打包 → `putRemoteAudiobook`。
  /// - Pull（远端有 ∧ 本端无有声书）→ `getRemoteAudiobook` 下载 →
  ///   `importAudioDatabasePackage` 解包落盘。
  ///
  /// **Pull 防孤儿约束**：`importAudioDatabasePackage` 只 upsert Audiobooks/SrtBooks
  /// 行，不创建 EpubBooks 行。故只对「本端已有同 bookKey 的 EPUB、但当前缺音频」的
  /// 远端项拉取——否则会落下没有书可绑的孤儿有声书行（这正是历史上选 push-only 的
  /// 动机）。无对应本地 EPUB 的远端有声书跳过并记一条 info 级 error，留给手动下载
  /// （书架远端书卡 / 同步对比对话框）补音频。拉取时用本地 EPUB 的 bookKey 作
  /// `bookKeyOverride`，保证写入行与本地 EPUB 字节相等可配对（徽章亮）。
  ///
  /// 仅当 client syncAudioBookFiles 开且 isInterconnect 时由 [run] 调用。
  /// 进度走 [SyncPhase.audiobooks]，临时文件 finally 清理，逐项错误进 report.errors 不中断。
  Future<void> _syncAudiobooksLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    final List<RemoteAudiobookInfo> remoteAudiobooks =
        await backend.listRemoteAudiobooks();
    final List<AudiobookRow> localAudiobooks = await _db.getAllAudiobooks();
    final List<EpubBookRow> localBooks = await _db.getAllEpubBooks();

    final Set<String> localKeys = <String>{
      for (final AudiobookRow ab in localAudiobooks) ab.bookKey,
    };
    // 纯 SRT（standalone）远端有声书（bookKey 空、身份=uid）**不进自动 union**：与
    // 远端独有 EPUB 一样是「手动下载才落地」（TODO-1291 / 书架远端占位卡），自动
    // sweep 只处理 srt-backed（bookKey 非空）有声书文件补拉，避免把独有 standalone
    // 书自动灌进对端，也避免空 bookKey 污染 diff。
    final Set<String> remoteKeys = <String>{
      for (final RemoteAudiobookInfo r in remoteAudiobooks)
        if (r.bookKey.isNotEmpty) r.bookKey,
    };
    // 本端已有 EPUB 的 bookKey 集合：Pull 只对「本端有书但缺音频」的远端项动作，
    // 避免落下无 EpubBooks 行可绑的孤儿有声书（importAudioDatabasePackage 不建书行）。
    final Set<String> localBookKeys = <String>{
      for (final EpubBookRow b in localBooks) b.bookKey,
    };

    final SyncKeyDiff diff = computeKeyUnionDiff(
      localKeys: localKeys,
      remoteKeys: remoteKeys,
    );

    // toPullAudioOnly（场景B）= 远端有 ∧ 本端无有声书 ∧ 本端已有同 bookKey
    // EPUB → 只补音频不重导 EPUB。这是「同步有声书文件」开关下**唯一**的 pull
    // 语义：只对本端已在库的书补/拉其音频文件。
    //
    // TODO-1291（用户决策 A · 解耦）：远端独有（本端完全没有这本书）的书
    // **不**在自动同步里导入/灌书架，即便远端书带有声书且 hasContent。这类书回归
    // 手动下载入口（compare 对比页 / 书架远端卡），与本类文档契约（见类头
    // :126-130「remote-only EPUBs stay remote until the user explicitly
    // downloads them」）一致。历史 TODO-873 的 toPullFullBook 自动灌书路径已在此
    // 摘除——它把「开启同步有声书文件」误当成「自动把远端独有书拉进书架」。
    final List<String> toPullAudioOnly = <String>[
      for (final String key in diff.toPull)
        if (localBookKeys.contains(key)) key,
    ];

    final int total = diff.toPush.length + toPullAudioOnly.length;
    int index = 0;

    // ── Push：本端独有 → 打包并上传 ─────────────────────────────────────────
    for (final String key in diff.toPush) {
      _emit(SyncPhase.audiobooks,
          itemIndex: index, itemTotal: total, title: key);
      File? tmp;
      try {
        final SrtBookRow? srt = await _db.getSrtBookByBookKey(key);
        if (srt == null) {
          report.errors
              .add('live push audiobook "$key": srtBook not found, skipping');
          index++;
          continue;
        }
        tmp = _tmpFile('.hibikiaudio');
        await _packages.exportAudioDatabasePackage(
          bookKey: key,
          srtBookUid: srt.uid,
          outputFile: tmp,
        );
        await backend.putRemoteAudiobook(
          key,
          tmp,
          onProgress: (double f) => _emit(SyncPhase.audiobooks,
              itemIndex: index, itemTotal: total, title: key, fileFraction: f),
        );
        report.audiobooksExported++;
      } catch (e) {
        report.noteError('live push audiobook "$key"', e);
      } finally {
        _safeDelete(tmp);
      }
      index++;
    }

    // ── Pull A（场景B）：远端有、本端有书但缺音频 → 下载并解包落盘 ────────────
    for (final String key in toPullAudioOnly) {
      _emit(SyncPhase.audiobooks,
          itemIndex: index, itemTotal: total, title: key);
      File? tmp;
      try {
        tmp = _tmpFile('.hibikiaudio');
        await backend.getRemoteAudiobook(
          key,
          tmp,
          onProgress: (double f) => _emit(SyncPhase.audiobooks,
              itemIndex: index, itemTotal: total, title: key, fileFraction: f),
        );
        // 用本地 EPUB 的 bookKey 作 override：远端 key 已等于本地 EPUB 的 bookKey
        // （toPull 已由 localBookKeys 筛过），显式 override 保写入行与 EPUB 可配对。
        await _packages.importAudioDatabasePackage(
          packageFile: tmp,
          audioDatabaseRoot: _audioDatabaseRoot,
          bookKeyOverride: key,
        );
        report.audiobooksImported++;
      } catch (e) {
        report.noteError('live pull audiobook "$key"', e);
      } finally {
        _safeDelete(tmp);
      }
      index++;
    }
  }

  /// 互联视频文件 live push（client→host，TODO §2.6「后续批」接线）。
  ///
  /// 直打对端 host 上传端点：枚举本地可上传单文件视频（[_isUploadableLocalVideo]，
  /// 排除流媒体 / 多集播放列表），对 host 尚无（按 bookUid）或尺寸不同的推上去。视频
  /// 身份键是 `VideoBooks.bookUid`（= host 端 [RemoteVideoInfo.id]，两端同源派生），故
  /// 直接按 uid union，重复上传同一视频 host 端 upsert 覆盖同一行、不产生重复。
  ///
  /// **upload-only**：host→client 方向仍是按需流式播放 / 手动下载（视频 GB 级不进
  /// 自动 pull），与云后端 [syncVideoAssets] 同律。互联 host 上传字节未混淆（与
  /// [putRemoteAudiobook] 同为裸 octet-stream），故 host 清单 [RemoteVideoInfo.sizeBytes]
  /// == 本地明文尺寸，可直接按尺寸判幂等（不必像云后端那样绕物理尺寸走清单）。
  ///
  /// 仅当 client syncVideoFiles 开且 isInterconnect 时由 [run] 调用。进度走
  /// [SyncPhase.videos]，逐项错误进 report.errors 不中断，[report.videosExported] 计上传数。
  Future<void> _syncVideosLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    // host 既有视频（uid → 清单条目；sizeBytes null=host 无法 stat）。
    final Map<String, RemoteVideoInfo> hostByUid = <String, RemoteVideoInfo>{
      for (final RemoteVideoInfo info in await backend.listRemoteVideos())
        info.id: info,
    };

    // 稳定顺序（uid 升序）遍历本地可上传视频，先算出真正要传的（host 无 / 尺寸不同），
    // 让进度分母只计实际上传数。字幕（BUG-964）：视频本轮上传 ⇒ 其全部 sidecar 一并
    // 推；host 已有视频但清单报无外挂字幕 ⇒ 只补推字幕（不重传视频）。
    final List<VideoBookRow> localVideos = <VideoBookRow>[
      for (final VideoBookRow v in await _db.allVideoBooks())
        if (_isUploadableLocalVideo(v)) v,
    ]..sort((VideoBookRow a, VideoBookRow b) => a.bookUid.compareTo(b.bookUid));

    final Map<String, List<String>?> sidecarDirCache =
        <String, List<String>?>{};
    final List<({VideoBookRow row, File file, bool pushVideo})> toPush =
        <({VideoBookRow row, File file, bool pushVideo})>[];
    for (final VideoBookRow v in localVideos) {
      final File file = File(v.videoPath);
      if (!file.existsSync()) {
        report.errors.add(
            'live push video "${v.title}": local file missing: ${v.videoPath}');
        continue;
      }
      final RemoteVideoInfo? host = hostByUid[v.bookUid];
      final int? hostSize = host?.sizeBytes;
      final int localSize = await file.length();
      // host 已有：尺寸可比且相等 ⇒ 跳过（幂等）；host 尺寸不可知（null）也跳过（无从
      // 判差异，避免每轮全量重传大视频，下轮 host stat 成功即自愈）。host 无 ⇒ 上传。
      final bool pushVideo =
          !(host != null && (hostSize == null || hostSize == localSize));
      // 字幕补推判据与视频同粒度：host 已有任一 sidecar 即跳过（改字幕内容/后加语言
      // 不重推，与视频同尺寸跳过一致）。
      // pushVideo==false 蕴含 host!=null（流程分析已提升，无需判空）。
      final bool pushSubtitles = (pushVideo || !host.hasSubtitle) &&
          _localSidecarSubtitles(v.videoPath, sidecarDirCache).isNotEmpty;
      if (!pushVideo && !pushSubtitles) continue;
      toPush.add((row: v, file: file, pushVideo: pushVideo));
    }

    final int total = toPush.length;
    int index = 0;
    // 老 host 无字幕端点（首个 404/405）后停止本轮后续字幕推送，只记一条可见提示
    // （与合集端点缺失的可见性纪律一致），不把每条视频都刷成一条错误。
    bool subtitleEndpointMissing = false;
    for (final ({VideoBookRow row, File file, bool pushVideo}) item in toPush) {
      final VideoBookRow v = item.row;
      _emit(SyncPhase.videos,
          itemIndex: index, itemTotal: total, title: v.title);
      bool videoOk = !item.pushVideo;
      if (item.pushVideo) {
        try {
          await backend.putRemoteVideo(
            v.bookUid,
            item.file,
            title: v.title,
            onProgress: (double f) => _emit(SyncPhase.videos,
                itemIndex: index,
                itemTotal: total,
                title: v.title,
                fileFraction: f),
          );
          report.videosExported++;
          videoOk = true;
        } catch (e) {
          report.noteError('live push video "${v.title}"', e);
        }
      }
      // 字幕跟着视频走：视频本轮失败就不推字幕（host 侧无行可挂）。
      if (videoOk && !subtitleEndpointMissing) {
        subtitleEndpointMissing = !await _pushVideoSubtitlesLive(
          report: report,
          backend: backend,
          row: v,
          sidecarDirCache: sidecarDirCache,
        );
        if (subtitleEndpointMissing) {
          report.errors.add(
              'live push subtitles: host has no subtitle endpoint (older app '
              'version) — update the host app to sync video subtitles');
        }
      }
      index++;
    }
  }

  /// 把 [row] 视频的全部本地 sidecar 字幕推给 host（BUG-964）。
  ///
  /// 返回 false 表示 host 无字幕端点（老版本，404/405），调用方停止本轮后续字幕
  /// 推送；单条字幕的其它失败进 [report.errors] 不中断。
  Future<bool> _pushVideoSubtitlesLive({
    required SyncRunReport report,
    required InterconnectSyncBackend backend,
    required VideoBookRow row,
    required Map<String, List<String>?> sidecarDirCache,
  }) async {
    final String stem = p.basenameWithoutExtension(row.videoPath);
    for (final File sub
        in _localSidecarSubtitles(row.videoPath, sidecarDirCache)) {
      final String suffix = p.basename(sub.path).substring(stem.length);
      try {
        final bool supported = await backend
            .putRemoteVideoSubtitle(row.bookUid, sub, suffix: suffix);
        if (!supported) return false;
      } catch (e) {
        report.noteError('live push subtitle "${p.basename(sub.path)}"', e);
      }
    }
    return true;
  }

  /// 列出 [videoPath] 同目录属于它的全部 sidecar 字幕文件（[listSidecarSubtitles]
  /// 匹配规则）。[sidecarDirCache] 按目录缓存一次 listSync（同目录多视频的 sweep
  /// 不重复扫盘）；目录不可读缓存 null → 返回空。
  List<File> _localSidecarSubtitles(
    String videoPath,
    Map<String, List<String>?> sidecarDirCache,
  ) {
    final String dir = p.dirname(videoPath);
    final List<String>? names = sidecarDirCache.putIfAbsent(dir, () {
      try {
        return Directory(dir)
            .listSync(followLinks: false)
            .whereType<File>()
            .map((FileSystemEntity f) => p.basename(f.path))
            .toList();
      } on FileSystemException {
        return null;
      }
    });
    if (names == null) return const <File>[];
    return <File>[
      for (final String name
          in listSidecarSubtitles(p.basenameWithoutExtension(videoPath), names))
        File(p.join(dir, name)),
    ];
  }

  /// Union-syncs local audio source DBs in the `__local_audio__` namespace.
  /// 资产名 = displayName（[LocalAudioDbEntry.path] 含本机时间戳，每机不同不可用）。
  /// push 本地独有（displayName 不在远端）/ pull 远端独有（displayName 不在本地）。
  ///
  /// 已知限制：displayName 无唯一约束，撞名按「同一库」union 跳过（与词典按 name
  /// 同语义）；真正的唯一性去重列为 follow-up。
  Future<void> syncLocalAudioPackages(SyncRunReport report) async {
    final String ns = await _backend.ensureNamespace(kSyncLocalAudioNamespace);
    final List<AssetEntry> remote = await _backend.listChildren(ns);

    final Set<String> remoteNames = <String>{
      for (final AssetEntry e in remote)
        if (!e.isFolder && e.name.endsWith(_localAudioAssetSuffix))
          e.name.substring(0, e.name.length - _localAudioAssetSuffix.length),
    };
    final Set<String> localNames = <String>{
      for (final LocalAudioDbEntry d in localAudioEntries) d.displayName,
    };

    // Resolve both sides' work first so progress has a real denominator. The
    // push side also drops libraries whose DB file is gone (nothing to send).
    final List<LocalAudioDbEntry> toPush = <LocalAudioDbEntry>[
      for (final LocalAudioDbEntry d in localAudioEntries)
        if (!remoteNames.contains(d.displayName) && File(d.path).existsSync())
          d,
    ];
    final List<AssetEntry> toPull = <AssetEntry>[
      for (final AssetEntry e in remote)
        if (!e.isFolder &&
            e.name.endsWith(_localAudioAssetSuffix) &&
            !localNames.contains(e.name
                .substring(0, e.name.length - _localAudioAssetSuffix.length)))
          e,
    ];
    final int total = toPush.length + toPull.length;
    int index = 0;

    // Push local-only.
    for (final LocalAudioDbEntry d in toPush) {
      _emit(SyncPhase.localAudio,
          itemIndex: index, itemTotal: total, title: d.displayName);
      final File dbFile = File(d.path);
      File? tmp;
      try {
        tmp = _tmpFile(_localAudioAssetSuffix);
        await _packages.exportLocalAudioPackage(
          displayName: d.displayName,
          enabled: d.enabled,
          sources: d.sources,
          dbFile: dbFile,
          outputFile: tmp,
        );
        await _backend.putAsset(
            ns, '${d.displayName}$_localAudioAssetSuffix', tmp,
            onProgress: (double f) => _emit(SyncPhase.localAudio,
                itemIndex: index,
                itemTotal: total,
                title: d.displayName,
                fileFraction: f));
        report.localAudioExported++;
      } catch (e) {
        report.noteError('export local audio "${d.displayName}"', e);
      } finally {
        _safeDelete(tmp);
      }
      index++;
    }

    // Pull remote-only.
    for (final AssetEntry e in toPull) {
      _emit(SyncPhase.localAudio,
          itemIndex: index, itemTotal: total, title: e.name);
      File? tmp;
      // Staging .db extracted from the package. AppModel.importSyncedLocalAudioDb
      // *copies* it into the library dir (never moves), so the staging copy
      // (potentially hundreds of MB) must be deleted here — otherwise every
      // pulled library leaks one .db into the OS temp dir.
      File? stagingDb;
      try {
        tmp = _tmpFile(_localAudioAssetSuffix);
        await _backend.getAsset(e.id, tmp,
            onProgress: (double f) => _emit(SyncPhase.localAudio,
                itemIndex: index,
                itemTotal: total,
                title: e.name,
                fileFraction: f));
        final LocalAudioPackageContents contents =
            await _packages.importLocalAudioPackage(
          packageFile: tmp,
          stagingDir: _tempDir,
        );
        stagingDb = contents.dbFile;
        if (onLocalAudioImported != null) {
          await onLocalAudioImported!(contents);
          report.localAudioImported++;
        }
      } catch (err) {
        report.noteError('import local audio "${e.name}"', err);
      } finally {
        _safeDelete(tmp);
        _safeDelete(stagingDb);
      }
      index++;
    }
  }

  /// Uploads the audiobook package (`audiobook.hibikiaudio`) inside each
  /// book's folder. A book with a local audiobook absent remotely is pushed;
  /// a remote package for a local book without audiobook is left untouched for
  /// explicit manual download flows.
  Future<void> syncAudiobookPackages(String root, SyncRunReport report) async {
    // A real "files transferred" denominator would need a findAsset network
    // round-trip per book before the loop; instead progress is keyed on the
    // book scan (k/N books), with the large pull/push fraction blended into the
    // current book's slot. The bar still advances monotonically.
    final List<EpubBookRow> books = await _db.getAllEpubBooks();
    final int total = books.length;
    for (int i = 0; i < total; i++) {
      final EpubBookRow book = books[i];
      _emit(SyncPhase.audiobooks,
          itemIndex: i, itemTotal: total, title: book.title);
      // BUG-619 / TODO-1329: skip empty-key books. bookKey == the sanitized
      // title, so an empty key means ensureBookFolder would collapse onto the
      // sync root and scatter the .hibikiaudio package into hibiki-data/ instead
      // of the per-book folder. (requireBookFolderName is the precise backstop.)
      if (book.bookKey.isEmpty) continue;
      File? tmp;
      try {
        final String bookKey = book.bookKey;
        final AudiobookRow? ab = await _db.getAudiobookByBookKey(bookKey);
        final SrtBookRow? srt = await _db.getSrtBookByBookKey(bookKey);
        final bool hasLocal = ab != null && srt != null;

        final String folderId = await _backend.ensureBookFolder(
          bookTitle: book.title,
          rootFolderId: root,
        );
        final AssetEntry? existing =
            await _backend.findAsset(folderId, kSyncAudiobookAssetName);

        if (hasLocal && existing == null) {
          tmp = _tmpFile('.hibikiaudio');
          await _packages.exportAudioDatabasePackage(
            bookKey: bookKey,
            srtBookUid: srt.uid,
            outputFile: tmp,
          );
          await _backend.putAsset(folderId, kSyncAudiobookAssetName, tmp,
              onProgress: (double f) => _emit(SyncPhase.audiobooks,
                  itemIndex: i,
                  itemTotal: total,
                  title: book.title,
                  fileFraction: f));
          report.audiobooksExported++;
        }
      } catch (e) {
        report.noteError('audiobook "${book.title}"', e);
      } finally {
        _safeDelete(tmp);
      }
    }
  }

  /// Deletes per-book metadata/cover files that spilled directly into the sync
  /// [root] (BUG-619 re-report / TODO-1340).
  ///
  /// A `progress_1_6_*` / `statistics_1_6_*` / `audioBook_1_6_*` / `cover_1_6.*`
  /// file must ALWAYS live inside its book folder `<root>/<sanitizedTitle>/`;
  /// one sitting as a direct child of the root is orphaned spill from the old
  /// empty-title `ensureBookFolder('')` collapse. TODO-1329 blocked new spills
  /// but never cleaned the residue, and the churning timestamp filenames plus
  /// the single-file `findSyncFileByPrefix` dedup let those copies pile up into
  /// many (`丢很多份`). Delete EVERY matching file, not just one.
  ///
  /// Only non-folder direct children are touched, so book folders and the
  /// reserved `__dictionaries__` / `__local_audio__` / `__aggregate__`
  /// namespaces (all folders) are never removed, and nothing legitimately
  /// writes a bare file into the root. Best-effort: a listing or per-file delete
  /// failure is recorded but never aborts the sweep.
  @visibleForTesting
  Future<void> pruneRootSpill(String root, SyncRunReport report) async {
    final List<AssetEntry> children;
    try {
      children = await _backend.listChildren(root);
    } catch (e) {
      report.noteError('prune root spill (list root)', e);
      return;
    }
    for (final AssetEntry e in children) {
      if (e.isFolder || !isTtuPerBookFileName(e.name)) continue;
      try {
        await _backend.deleteAsset(e.id);
        report.rootSpillFilesRemoved++;
      } catch (err) {
        report.noteError('prune root spill "${e.name}"', err);
      }
    }
  }

  void _safeDelete(File? f) {
    if (f == null) return;
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (_) {
      // Best-effort temp cleanup.
    }
  }
}

/// 下载远端书文件夹 [folderId] 里的 `.epub` 内容资产并导入为本地书。
/// 返回 true=导入成功；false=该文件夹没有 `.epub`（发送方关了内容同步，跳过）。
/// 传输/导入失败时抛出，交调用方决定如何提示。临时文件用后即删。
Future<bool> importRemoteBookFolder({
  required HibikiDatabase db,
  required SyncBackend backend,
  required String folderId,
  required Directory tempDir,
  Directory? audioDatabaseRoot,
  void Function(double fraction)? onProgress,
}) async {
  final List<AssetEntry> children = await backend.listChildren(folderId);
  AssetEntry? epub;
  for (final AssetEntry e in children) {
    if (!e.isFolder && e.name.toLowerCase().endsWith('.epub')) {
      epub = e;
      break;
    }
  }
  if (epub == null) return false;

  tempDir.createSync(recursive: true);
  final File tmp = File(p.join(
    tempDir.path,
    'hibiki_remote_${DateTime.now().microsecondsSinceEpoch}.epub',
  ));
  try {
    await backend.getAsset(epub.id, tmp, onProgress: onProgress);
    final String importedBookKey = await EpubImporter.importFromPath(
      db: db,
      filePath: tmp.path,
      fileName: epub.name,
    );
    // TODO-1165：按标签名重建云盘书标签映射（sidecar 由 push 侧写在同文件夹，只增
    // 不删）。复用已列出的 children，不再多发一次 listChildren。
    await _applyRemoteBookFolderTags(db, backend, children, importedBookKey);
    // 云后端有声书 pull：下载远端书文件夹时若带 `audiobook.hibikiaudio`（push 侧
    // syncAudiobookPackages 写在同文件夹），且调用方注入了 [audioDatabaseRoot]，一并
    // 补下音频包。修复历史缺口——此前 syncAudiobookPackages 是 upload-only、
    // importRemoteBookFolder 只找 `.epub`，导致云有声书「只上传拿不回」。best-effort：
    // 音频补下失败不影响 EPUB 已成功导入。
    if (audioDatabaseRoot != null) {
      await _pullRemoteFolderAudiobook(
        db: db,
        backend: backend,
        children: children,
        bookKey: importedBookKey,
        audioDatabaseRoot: audioDatabaseRoot,
        tempDir: tempDir,
      );
    }
    // per-book 自定义 CSS：LWW 合并同文件夹 book_css.json，把较新内容写穿 extractDir。
    await _applyRemoteBookFolderCss(db, backend, children, importedBookKey);
    return true;
  } finally {
    try {
      if (tmp.existsSync()) tmp.deleteSync();
    } catch (_) {
      // best-effort temp cleanup
    }
  }
}

/// 若远端书文件夹 [children] 里存在 `audiobook.hibikiaudio`（[kSyncAudiobookAssetName]），
/// 下载并用本地刚导入 EPUB 的 [bookKey] 作 `bookKeyOverride` 解包落盘（修复云后端有声书
/// 「只上传拿不回」缺口）。无音频资产是常态（普通书）——静默返回。best-effort：下载/
/// 解包失败仅吞掉（EPUB 已成功导入，不因音频回退整本失败）。
Future<void> _pullRemoteFolderAudiobook({
  required HibikiDatabase db,
  required SyncBackend backend,
  required List<AssetEntry> children,
  required String bookKey,
  required Directory audioDatabaseRoot,
  required Directory tempDir,
}) async {
  AssetEntry? audioAsset;
  for (final AssetEntry e in children) {
    if (!e.isFolder && e.name == kSyncAudiobookAssetName) {
      audioAsset = e;
      break;
    }
  }
  if (audioAsset == null) return;

  final File tmp = File(p.join(
    tempDir.path,
    'hibiki_remote_audio_${DateTime.now().microsecondsSinceEpoch}.hibikiaudio',
  ));
  try {
    await backend.getAsset(audioAsset.id, tmp);
    await SyncAssetPackageService(db: db).importAudioDatabasePackage(
      packageFile: tmp,
      audioDatabaseRoot: audioDatabaseRoot,
      bookKeyOverride: bookKey,
    );
  } catch (_) {
    // best-effort：音频补下失败不影响 EPUB 已成功导入。
  } finally {
    try {
      if (tmp.existsSync()) tmp.deleteSync();
    } catch (_) {
      // best-effort temp cleanup
    }
  }
}

/// 读取云盘书文件夹里的标签 sidecar（[kSyncBookTagsAssetName]）并 LWW-element-set 合并进
/// [bookKey] 本地标签（TODO-1165 / tags 稳健档）。[children] 复用 [importRemoteBookFolder]
/// 已列出的目录项。缺 sidecar（旧端未写）安全降级为不动本地。v2 sidecar 带 tagsAddedAt +
/// tagTombstones → 按名 max(add) vs max(removed) 裁决（删除/改名传播、防复活）；v1 旧
/// sidecar 只有 tags 名单 → 合成 addedAt=1，退化为「只增且尊重本地移除墓碑」（向后兼容）。
Future<void> _applyRemoteBookFolderTags(
  HibikiDatabase db,
  SyncBackend backend,
  List<AssetEntry> children,
  String bookKey,
) async {
  AssetEntry? sidecar;
  for (final AssetEntry e in children) {
    if (!e.isFolder && e.name == kSyncBookTagsAssetName) {
      sidecar = e;
      break;
    }
  }
  if (sidecar == null) return;
  final Object? json = await backend.getJsonAsset(sidecar.id);
  final ({Map<String, int> addedAt, Map<String, int> tombstones}) parsed =
      parseTagSidecar(json);
  if (parsed.addedAt.isEmpty && parsed.tombstones.isEmpty) return;
  await db.mergeRemoteBookTags(
    bookKey,
    remoteAddedAt: parsed.addedAt,
    remoteTombstones: parsed.tombstones,
  );
}

/// 读取云盘书文件夹里的 CSS sidecar（[kSyncBookCssAssetName]）并 LWW 合并进 [bookKey]：
/// 按 relativePath 取 updatedAt 较新，把内容/重置写穿书的 extractDir（磁盘是渲染真相源，
/// DB 只是时间戳载体）。缺 sidecar / 本书无对应 CSS 文件 / 反查不到 extractDir 一律安全跳过。
Future<void> _applyRemoteBookFolderCss(
  HibikiDatabase db,
  SyncBackend backend,
  List<AssetEntry> children,
  String bookKey,
) async {
  AssetEntry? sidecar;
  for (final AssetEntry e in children) {
    if (!e.isFolder && e.name == kSyncBookCssAssetName) {
      sidecar = e;
      break;
    }
  }
  if (sidecar == null) return;
  final Object? json = await backend.getJsonAsset(sidecar.id);
  final Map<String, ({String content, bool deleted, int updatedAt})> remote =
      parseBookCssSidecar(json);
  if (remote.isEmpty) return;
  final List<({String relativePath, String content, bool deleted})> changed =
      await db.mergeRemoteBookCss(bookKey, remote);
  if (changed.isEmpty) return;
  final EpubBookRow? book = await db.getEpubBook(bookKey);
  final String? extractDir = book?.extractDir;
  if (extractDir == null || extractDir.isEmpty) return;
  final BookCssRepository repo = BookCssRepository(extractDir);
  final Map<String, CssFileEntry> byRel = <String, CssFileEntry>{
    for (final CssFileEntry e in repo.discoverCssFiles()) e.relativePath: e,
  };
  for (final ({String relativePath, String content, bool deleted}) c
      in changed) {
    final CssFileEntry? entry = byRel[c.relativePath];
    if (entry == null) continue; // 本书无此 CSS 文件（版本差异）→ 跳过
    try {
      if (c.deleted) {
        repo.resetFile(entry);
      } else {
        repo.saveCss(entry, c.content);
      }
    } catch (_) {
      // best-effort：单个 CSS 写盘失败不影响其余（磁盘/权限异常）。
    }
  }
}

/// 解析 CSS sidecar JSON 为 LWW 输入：`{files:{relativePath:{content,deleted,updatedAt}}}`。
/// 非 Map / 缺 updatedAt / 坏字段一律安全跳过，绝不抛 FormatException。测试可见。
@visibleForTesting
Map<String, ({String content, bool deleted, int updatedAt})>
    parseBookCssSidecar(Object? json) {
  if (json is! Map) {
    return const <String, ({String content, bool deleted, int updatedAt})>{};
  }
  final Object? files = json['files'];
  if (files is! Map) {
    return const <String, ({String content, bool deleted, int updatedAt})>{};
  }
  final Map<String, ({String content, bool deleted, int updatedAt})> out =
      <String, ({String content, bool deleted, int updatedAt})>{};
  files.forEach((Object? k, Object? v) {
    final String rel = k?.toString() ?? '';
    if (rel.isEmpty || v is! Map) return;
    final Object? updatedAt = v['updatedAt'];
    final int? ms = updatedAt is int
        ? updatedAt
        : (updatedAt is num
            ? updatedAt.toInt()
            : int.tryParse(updatedAt?.toString() ?? ''));
    if (ms == null) return;
    out[rel] = (
      content: v['content']?.toString() ?? '',
      deleted: v['deleted'] == true,
      updatedAt: ms,
    );
  });
  return out;
}

/// 解析标签 sidecar JSON 为 LWW 输入（tags 稳健档）。v2 带 `tagsAddedAt` / `tagTombstones`
/// （名→毫秒戳）直接用；否则 v1 只有 `tags` 名单 → 合成 addedAt=1（正数，胜过缺席但输给
/// 任何本地墓碑，保持「只增 + 尊重本地移除」的旧语义）。非 Map / 坏字段一律安全降级为空，
/// 绝不抛 FormatException。测试可见。
@visibleForTesting
({Map<String, int> addedAt, Map<String, int> tombstones}) parseTagSidecar(
    Object? json) {
  if (json is! Map) {
    return (addedAt: <String, int>{}, tombstones: <String, int>{});
  }
  final Map<String, int> addedAt = _parseNameIntMap(json['tagsAddedAt']);
  final Map<String, int> tombstones = _parseNameIntMap(json['tagTombstones']);
  if (addedAt.isNotEmpty || tombstones.isNotEmpty) {
    return (addedAt: addedAt, tombstones: tombstones);
  }
  final Map<String, int> v1 = <String, int>{
    for (final String name in _bookTagNamesFromSidecar(json))
      if (name.isNotEmpty) name: 1,
  };
  return (addedAt: v1, tombstones: <String, int>{});
}

/// 从标签 sidecar JSON 解析非空标签名列表（v1 兼容）。非 Map / `tags` 非 List / 缺键
/// 一律返回空列表——向后兼容旧格式，绝不对缺字段抛 FormatException。
List<String> _bookTagNamesFromSidecar(Object? json) {
  if (json is! Map) return const <String>[];
  final Object? raw = json['tags'];
  if (raw is! List) return const <String>[];
  return <String>[
    for (final Object? item in raw)
      if (item != null && item.toString().isNotEmpty) item.toString(),
  ];
}

/// 解析 `{name: ms}` 映射（值容忍 int / num / 数字串）。非 Map / 空名 / 非数值值跳过。
Map<String, int> _parseNameIntMap(Object? raw) {
  if (raw is! Map) return <String, int>{};
  final Map<String, int> out = <String, int>{};
  raw.forEach((Object? k, Object? v) {
    final String name = k?.toString() ?? '';
    if (name.isEmpty) return;
    final int? ms = v is int
        ? v
        : (v is num ? v.toInt() : int.tryParse(v?.toString() ?? ''));
    if (ms != null) out[name] = ms;
  });
  return out;
}

/// 两个 `{name: ms}` 时钟按名取 max 并集（tags 稳健档：视频清单条目累积他端知识）。
Map<String, int> _unionMaxIntMap(Map<String, int> a, Map<String, int> b) {
  final Map<String, int> out = <String, int>{...a};
  for (final MapEntry<String, int> e in b.entries) {
    out[e.key] = out.containsKey(e.key)
        ? (out[e.key]! > e.value ? out[e.key]! : e.value)
        : e.value;
  }
  return out;
}
