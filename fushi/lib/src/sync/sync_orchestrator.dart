import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:fushi/src/epub/book_css_repository.dart';
import 'package:fushi/src/epub/epub_importer.dart';
import 'package:fushi/src/media/video/video_sidecar.dart'
    show listSidecarSubtitles;
import 'package:fushi/src/models/local_audio_manager.dart';
import 'package:fushi/src/sync/collection_manifest.dart';
import 'package:fushi/src/sync/manga_sync_package.dart' show repackageMangaBook;
import 'package:fushi/src/sync/collection_sync_engine.dart';
import 'package:fushi/src/sync/deletion_propagation.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/override_title_lookup.dart';
import 'package:fushi/src/sync/interconnect_service_config.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/aggregate_sync_service.dart';
import 'package:fushi/src/sync/sync_asset_package_service.dart';
import 'package:fushi/src/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_remote_listing.dart';
import 'package:fushi/src/sync/sync_manager.dart';
import 'package:fushi/src/sync/sync_progress.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/ttu_filename.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/video_manifest.dart';
import 'package:fushi_audio/fushi_audio.dart'
    show FavoriteSentence, FavoriteSentenceRepository;
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

part 'sync_orchestrator/aggregate.part.dart';
part 'sync_orchestrator/collections.part.dart';
part 'sync_orchestrator/tombstones.part.dart';
part 'sync_orchestrator/books.part.dart';
part 'sync_orchestrator/videos.part.dart';
part 'sync_orchestrator/audiobooks.part.dart';
part 'sync_orchestrator/dictionaries.part.dart';
part 'sync_orchestrator/local_audio.part.dart';

/// Reserved top-level folder (under the backend root) that holds dictionary
/// packages. It lives alongside the per-book folders, so every place that
/// treats root children as *books* must skip it ([isReservedSyncFolderName]).
const String kSyncDictionaryNamespace = '__dictionaries__';

/// Asset file name (inside a book's folder) holding the audiobook package
/// (audio + subtitles + cues + alignment), produced by
/// [SyncAssetPackageService.exportAudioDatabasePackage].
const String kSyncAudiobookAssetName = 'audiobook.fushiaudio';

/// Hibiki 时代写下的同一资产名（W9-4 改名前）。**只读不写**——见
/// [_legacyDictionaryAssetSuffix] 的完整理由。
const String kLegacySyncAudiobookAssetName = 'audiobook.hibikiaudio';

const String _dictionaryAssetSuffix = '.fushidict';

/// Hibiki 时代写下的同一后缀（W9-4 改名前）。**只读不写**：云根迁移只把根文件夹
/// 改名、内容原样保留，用户云上仍有大量旧后缀资产；listing 只认新后缀会把它们
/// 当陌生文件跳过 = 用户的远端词典/有声书凭空消失。写侧一律新后缀，旧资产读得到、
/// 不再被写入，随用户下一次推送自然退场。
const String _legacyDictionaryAssetSuffix = '.hibikidict';

/// 该资产名是否是（新或旧）词典包。
bool _isDictionaryAsset(String name) =>
    name.endsWith(_dictionaryAssetSuffix) ||
    name.endsWith(_legacyDictionaryAssetSuffix);

/// 剥掉（新或旧）词典包后缀，得到词典显示名；两种后缀都不匹配时原样返回。
String _stripDictionaryAssetSuffix(String name) {
  if (name.endsWith(_dictionaryAssetSuffix)) {
    return name.substring(0, name.length - _dictionaryAssetSuffix.length);
  }
  if (name.endsWith(_legacyDictionaryAssetSuffix)) {
    return name.substring(0, name.length - _legacyDictionaryAssetSuffix.length);
  }
  return name;
}

/// Reserved top-level folder holding local-audio source packages (pronunciation
/// DB + config manifest), alongside the dictionary namespace and per-book
/// folders. Must be filtered from any listing that treats root children as
/// books ([isReservedSyncFolderName]).
const String kSyncLocalAudioNamespace = '__local_audio__';

const String _localAudioAssetSuffix = '.fushiaudiolib';

/// Hibiki 时代写下的同一后缀（W9-4 改名前）。**只读不写**——理由同
/// [_legacyDictionaryAssetSuffix]。
const String _legacyLocalAudioAssetSuffix = '.hibikiaudiolib';

/// 该资产名是否是（新或旧）本地音源包。
bool _isLocalAudioAsset(String name) =>
    name.endsWith(_localAudioAssetSuffix) ||
    name.endsWith(_legacyLocalAudioAssetSuffix);

/// 剥掉（新或旧）本地音源包后缀；两种后缀都不匹配时原样返回。
String _stripLocalAudioAssetSuffix(String name) {
  if (name.endsWith(_localAudioAssetSuffix)) {
    return name.substring(0, name.length - _localAudioAssetSuffix.length);
  }
  if (name.endsWith(_legacyLocalAudioAssetSuffix)) {
    return name.substring(0, name.length - _legacyLocalAudioAssetSuffix.length);
  }
  return name;
}

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
  /// cached `fushiBooksProvider` still holds the pre-sync progress and must be
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

  /// 本轮呈现的删除候选里最大的远端 deletedAt，**按通道分开记**（BUG-1579）。
  ///
  /// UI 层在用户处理完确认框后据此推进
  /// [SyncRepository.setDeletionTombstonesBaselineMs]（=已复核到此时刻的删除标记），
  /// 恰好压制已复核的、放行更新的删除。空 map = 本轮无候选。
  ///
  /// 为什么是 map 而不是一个 int：手动同步会把两条通道的报告 [mergeFrom] 成一份，
  /// 一个标量在那一刻就把「这个时刻是相对哪个远端的」丢了——推进任一通道的基线都
  /// 会用另一条通道的时刻去压制自己还没复核过的删除。
  final Map<String, int> deletionTombstonesHighWaterMsByScope = <String, int>{};

  /// 记一条通道本轮复核到的删除时刻（取该通道的 max）。
  ///
  /// 调用方**必须**先确认本轮完整读到了该通道的全部远端墓碑：这个值一旦落地就成了
  /// 「此刻之前的删除都已复核」的断言，而没读到的那些标记会被它连坐压制（BUG-1934）。
  void noteDeletionHighWater(SyncChannelScope scope, int deletedAt) {
    final int? prev = deletionTombstonesHighWaterMsByScope[scope.id];
    if (prev == null || deletedAt > prev) {
      deletionTombstonesHighWaterMsByScope[scope.id] = deletedAt;
    }
  }

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
    // 逐槽位取 max：两条通道的复核时刻各归各的轴，绝不折成一个标量（那会用一条
    // 通道的时刻去推进另一条通道的基线）。
    other.deletionTombstonesHighWaterMsByScope
        .forEach((String scopeId, int at) {
      final int? prev = deletionTombstonesHighWaterMsByScope[scopeId];
      if (prev == null || at > prev) {
        deletionTombstonesHighWaterMsByScope[scopeId] = at;
      }
    });
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

/// 一次资产传输的方向。
///
/// 方向以前是**隐含**的：一个 `sync_*_enabled` 开关开着就双向 union，关着就完全不
/// 传，用户没法表达「现在把本机词典推上去」这种一次性意图。词典 / 本地音频源数据库
/// 改成显式的上传 / 下载动作后，方向成了调用点必须携带的数据，而不是从开关反推出
/// 来的行为。
///
/// [both] 不是兼容补丁：互联通道的词典在「上传词典到互联对端」开关下**仍然**是双向
/// union（BUG-988 的通道解耦语义），那是真实存在的第三种方向。
enum SyncAssetDirection {
  /// 只把本端独有的资产推给远端。
  upload,

  /// 只把远端独有的资产拉到本端。
  download,

  /// 双向 union（自动同步路径）。
  both;

  /// 本方向是否包含「拉远端独有」。
  bool get pulls => this != SyncAssetDirection.upload;

  /// 本方向是否包含「推本端独有」。
  bool get pushes => this != SyncAssetDirection.download;
}

/// 显式传输的资产类别（[SyncOrchestrator.runAssetTransferOnly]）。
enum SyncAssetKind {
  /// 词典包（含导入的词典资源）。
  dictionary,

  /// 本地音频来源数据库（`.db` + 来源配置）。
  localAudio,
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
/// 词典与本地音频源数据库**不再随自动同步跑**：它们改由设置页的显式「上传 /
/// 下载」动作驱动（[runAssetTransferOnly]），方向由用户在点击时给出，而不是从一个
/// 开关反推。唯一例外是互联通道的词典 —— 「上传词典到互联对端」开关仍按 BUG-988
/// 的通道语义驱动一轮双向 union，本次不动。
class SyncOrchestrator {
  SyncOrchestrator({
    required FushiDatabase db,
    required SyncBackend backend,
    required Directory dictionaryResourceRoot,
    required Directory audioDatabaseRoot,
    required Directory tempDir,
    this.deviceId = '',
    required this.syncStats,
    this.syncFavorites = true,
    required this.syncAudioBookPosition,
    required this.syncContent,
    required this.syncAudioBookFiles,
    this.syncVideoFiles = false,
    required this.syncDictionary,
    this.localAudioEntries = const <LocalAudioDbEntry>[],
    this.onLocalAudioImported,
    this.statsSyncMode = StatisticsSyncMode.merge,
    this.onProgress,
  })  : _db = db,
        _backend = backend,
        _dictionaryResourceRoot = dictionaryResourceRoot,
        _audioDatabaseRoot = audioDatabaseRoot,
        _tempDir = tempDir,
        _scope = syncChannelScopeOf(backend),
        _packages = SyncAssetPackageService(db: db);

  final FushiDatabase _db;
  final SyncBackend _backend;

  /// 本轮编排跑的是哪条通道（BUG-1579 / BUG-1580）。合集因果基线、删除墓碑消费
  /// 基线、整轮冷却戳、聚合快照哈希都是「本端相对**某一个远端**」的账，双通道并存
  /// 时共用一份键就会互相覆盖/互相压制，故一律按槽位分开记。
  final SyncChannelScope _scope;
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

  /// 收藏词 / 收藏句是否参与聚合同步。互联通道由「共享收藏夹」开关驱动，与
  /// [syncStats] 互相独立；云通道两者同源（见 [ChannelSyncFlags.syncFavorites]）。
  /// 默认 true：省略该参数的既有调用点行为不变。
  final bool syncFavorites;
  final bool syncAudioBookPosition;
  final bool syncContent;
  final bool syncAudioBookFiles;

  /// 是否把本地视频文件上传到云 `__videos__/` 命名空间（多端库联合视图 §2.6）。默认
  /// false：视频体积大，须用户显式 opt-in。仅云后端生效（互联走 host API，暂不接线）。
  final bool syncVideoFiles;

  final bool syncDictionary;

  /// 本地音频来源（DB 文件 + 配置）传输所需的数据。orchestrator 不依赖 AppModel：
  /// 导出用的条目列表由 [localAudioEntries] 注入，导入注册经 [onLocalAudioImported]
  /// 回调。这一维度不再随自动同步跑，只由 [runAssetTransferOnly] 的显式上传 / 下载
  /// 驱动。
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

    // ── 增量同步（TODO-2656）：把 O(书数) 次列举压成一次 ──────────────────
    //
    // 唯一的改动是「远端那批文件名怎么拿到」：能一次拿全就一次拿全，拿不到就照旧
    // 逐本问。每本书之后走的判定逻辑一字未改，也没有任何「快照说没变所以跳过」的
    // 中间结论——跳过是单边不安全的操作，一旦所依赖的结论与远端实情不符，漏掉的
    // 那次对端更新会被本地 LWW 覆盖掉，那是丢数据而不是慢。
    final String root = await _backend.findOrCreateRootFolder();
    final SyncBackend backend = _backend;
    final RemoteListingSnapshot? listing = backend is RemoteListingCapable
        ? await (backend as RemoteListingCapable).snapshotListing(root)
        : null;

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
    // 书阶段与后续各阶段（词典/音频/进度/合集/墓碑）互相独立，但它是整条流水线里
    // 唯一没有自带 try/catch 的阶段——它一抛，合集/墓碑等后续阶段整轮到不了
    // （客户端设备从不本机建合集、watcher 轻量路径也永远不触发，于是 host 合集
    // 永远落不了库、库页永远散卡）。对齐其余 _sync*Live 阶段的形状：失败记
    // report.errors，流水线继续。
    //
    // SyncAuthError 例外放行：它冲出 run() 是承重契约——manual_sync_ui 靠捕获它
    // 登出并引导重新登录（TODO-836 / BUG-1323），吞成 report.errors 会把「凭据已
    // 失效」降级成一条无操作性的杂项错误；且鉴权死了后续阶段本来也无法工作。
    List<SyncBookResult> bookResults = const <SyncBookResult>[];
    try {
      bookResults = await SyncManager(
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
        listing: listing,
        onBookProgress: (int done, int total, String title) {
          readingDone = done;
          readingTotal = total;
          readingTitle = title;
          _emit(SyncPhase.readingData,
              itemIndex: done, itemTotal: total, title: title);
        },
      );
    } on SyncAuthError {
      rethrow;
    } catch (e) {
      report.errors.add('books: $e');
    }
    _collectConflicts(bookResults, report);

    // 词典只剩互联通道会自动跑（「上传词典到互联对端」开关，BUG-988 的通道语义）。
    // 云通道的 [syncDictionary] 恒为 false：那一侧的词典改由设置页的显式上传 /
    // 下载驱动，见 [runAssetTransferOnly]。
    if (syncDictionary) {
      await syncDictionaries(report, direction: SyncAssetDirection.both);
    }

    // 本地音频源数据库两条通道都不再自动传（无论互联还是云）：它没有任何开关了，
    // 只由 [runAssetTransferOnly] 的显式动作驱动。
    //
    // 互联（InterconnectSyncBackend）有声书包走 live 端点；
    // 云后端仍走原暂存路径（不变）。
    if (isInterconnect) {
      if (syncAudioBookFiles) await _syncAudiobooksLive(report, b);
      // 互联视频文件 live push（client→host）：单文件本地视频经 host 上传端点注册进
      // host 视频库。与云后端 syncVideoAssets 同为 syncVideoFiles 开关驱动、同为
      // upload-only（host→client 仍走按需流式/下载）。
      if (syncVideoFiles) await _syncVideosLive(report, b);
    } else {
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
      // 互联聚合（统计 + 收藏）live 双向合并（TODO-1056 phase C）。两族各自由互联
      // 页的「共享统计 / 共享收藏夹」开关控制（默认均 true = 拆开关前的行为），裁剪
      // 在 [AggregateSyncService.syncOverClient] 内按族做，两族都关时整轮不发请求。
      // 互联无 per-device 快照文件、不依赖 deviceId：host 单份权威快照，client GET →
      // 并集折叠 → 写回本地 → PUT 回 host（host 再 MAX/并集折叠进自己 DB）。
      if (syncStats || syncFavorites) await _syncAggregateLive(report, b);
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
        .setLastSyncMs(_scope, DateTime.now().millisecondsSinceEpoch);

    return report;
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

  /// 只跑**一类资产、一个方向**的轻量传输 —— 设置页「词典 / 本地音频数据库」两行
  /// 的显式上传 / 下载动作走这条路。
  ///
  /// 与 [runCollectionsOnly] 同范式：**不写** lastSyncMs 冷却戳（那是完整 sweep 的
  /// 语义），不碰任何其它维度，内部逐项错误自己进 [SyncRunReport.errors] 不中断。
  ///
  /// 云路径的 `ensureNamespace` 依赖同步根已解析（与 [run] 开头一致），故先
  /// [SyncBackend.findOrCreateRootFolder]；互联 live 路径直打对端端点不需要根，
  /// 也就不为它多跑一次网络往返。
  Future<SyncRunReport> runAssetTransferOnly({
    required SyncAssetKind kind,
    required SyncAssetDirection direction,
  }) async {
    final SyncRunReport report = SyncRunReport();
    if (_backend is! InterconnectSyncBackend) {
      await _backend.findOrCreateRootFolder();
    }
    switch (kind) {
      case SyncAssetKind.dictionary:
        await syncDictionaries(report, direction: direction);
      case SyncAssetKind.localAudio:
        await syncLocalAudioSources(report, direction: direction);
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
      int baseline = await repo.getCollectionsSyncBaselineMs(_scope);
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
        await repo.setCollectionsSyncBaselineMs(_scope, nextBaseline);
      }
    } catch (e) {
      report.noteError('collections sync', e);
    }
  }

  /// 测试入口：直接调用 [_syncCollectionsLive]（private 方法对测试文件不可见）。
  @visibleForTesting
  Future<void> syncCollectionsLiveForTest(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) =>
      _syncCollectionsLive(report, backend);

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
  ///
  /// **完整观测不变式**（BUG-1934）：只有本轮把列出的标记**全部**读成了 marker，才登记
  /// [SyncRunReport.noteDeletionHighWater]（=允许 UI 推进基线）。少读一条就闭嘴——基线
  /// 是标量，推过头会把那条没读到的、deletedAt 更小的删除永久压成「旧闻」。
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
      // itemKey → deletedAt（同资产多标记取较新；理论上主键唯一，防御性取 max）。
      final DeletionTombstoneEntries remoteTombstones =
          <String, Map<String, int>>{};
      // 本轮是否**完整**观测了远端标记集合：列出来了却没读成 marker 的每一条都置假。
      // 基线的语义是「已复核到此时刻的删除」，只有完整观测撑得起这句话（BUG-1934，
      // 见下方推进点的长注释）。
      bool scanComplete = true;
      final List<AssetEntry> children = await _backend.listChildren(ns);
      for (final AssetEntry e in children) {
        if (e.isFolder) continue;
        Object? json;
        try {
          json = await _backend.getJsonAsset(e.id);
        } catch (err) {
          scanComplete = false;
          report.noteError('deletion tombstone "${e.name}" unreadable', err);
          continue;
        }
        if (json == null) {
          // listChildren 刚列到它、读回来却是空：要么本轮被对端删了（下轮不再列出，
          // 自愈），要么后端把读失败映射成了 null 而不是抛（[SftpSyncBackend
          // .getJsonAsset] 就是这样吞 SyncBackendError 的）。两种都不是「已观测」，
          // 按不完整处理——静默 continue 会让后者变成一次无声的永久压制。
          scanComplete = false;
          report.noteError(
              'deletion tombstone "${e.name}" unreadable', 'empty response');
          continue;
        }
        final parsed = parseDeletionTombstoneJson(json);
        if (parsed == null) {
          // 读到了但内容不合法（截断上传 / 非本协议文件）。这是**永久**状态，重试不会
          // 变好，故不置 scanComplete=false（否则基线被一个坏文件永久钉死，用户每轮
          // 重看同一批确认框）。只如实记一条，别再静默丢。
          report.noteError(
              'deletion tombstone "${e.name}" malformed', 'skipped');
          continue;
        }
        final Map<String, int> byKey = remoteTombstones.putIfAbsent(
            parsed.mediaType, () => <String, int>{});
        final int? prev = byKey[parsed.itemKey];
        if (prev == null || parsed.deletedAt > prev) {
          byKey[parsed.itemKey] = parsed.deletedAt;
        }
      }

      final DeletionPresentEntries present =
          await _collectPresentDeletionKeys();
      int baseline = await repo.getDeletionTombstonesBaselineMs(_scope);
      if (baseline > nextBaseline) baseline = nextBaseline; // 时钟回拨钳制。
      bool heldBaseline = false;

      // deleteLocal 方向：远端有标记 ∧ 本地在库 ∧ 该标记管得着本地这条
      // （BUG-2044 的存在起始时刻仲裁在 [computeDeletionPropagation] 内统一做）。
      // localTombstones/remotePresent 传空 ⇒ 只产 deleteLocal，不产 deleteRemote
      // （本设备的删除靠发布标记让对端各自消费）。
      final List<DeletionPropagationCandidate> raw = computeDeletionPropagation(
        localTombstones: const <String, Map<String, int>>{},
        remoteTombstones: remoteTombstones,
        localPresent: present,
        remotePresent: const <String, Map<String, int?>>{},
      );
      for (final DeletionPropagationCandidate c in raw) {
        if (c.direction != DeletionPropagationDirection.deleteLocal) continue;
        final int? at = remoteTombstones[c.mediaType]?[c.itemKey];
        if (at == null || at <= baseline) continue; // 旧闻 / 已处理，不再弹。
        report.deletionCandidates.add(c);
        // BUG-1934：读失败的标记必须挡住基线推进。基线是**标量**，UI 复核完这批就把它
        // 推到本轮最大 deletedAt，于是任何 deletedAt 更小、本轮恰好没读出来的标记，下轮
        // 就落进上面那句 `at <= baseline` 的旧闻分支——永久不再弹，用户在对端删掉的东西
        // 在本机静默留存。触发它只要一次 TLS 握手失败（HandshakeException）。候选照常
        // 上报（该弹的还得弹），只是不认领「已复核到此刻」这个断言，下轮读全了再推进。
        // 互联通道无需同样处理：它一次 GET 取回全部墓碑，失败即整体抛出，无部分观测。
        if (scanComplete) {
          report.noteDeletionHighWater(_scope, at);
        } else {
          heldBaseline = true;
        }
      }
      if (heldBaseline) {
        report.errors.add('deletion tombstones scan incomplete; '
            'consumption baseline held until a complete read');
      }
    } catch (e) {
      report.noteError('deletion tombstones sync', e);
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
    InterconnectSyncBackend backend, {
    SyncAssetDirection direction = SyncAssetDirection.both,
  }) =>
      _syncLocalAudioLive(report, backend, direction);

  /// 测试入口：直接调用 [_syncAudiobooksLive]。
  @visibleForTesting
  Future<void> syncAudiobooksLiveForTest(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) =>
      _syncAudiobooksLive(report, backend);

  /// Union-syncs dictionaries. 互联（InterconnectSyncBackend）→ 直读对端实时库（无暂存）；
  /// 云后端 → 走现有 __dictionaries__ 暂存路径（不变）。无旧设备故无能力探测。
  Future<void> syncDictionaries(
    SyncRunReport report, {
    required SyncAssetDirection direction,
  }) async {
    final SyncBackend b = _backend;
    if (b is InterconnectSyncBackend) {
      await _syncDictionariesLive(report, b, direction);
      return;
    }
    await _syncDictionariesStaged(report, direction);
  }

  /// 本地音频源数据库的通道分派（与 [syncDictionaries] 同形）：互联走 live 端点，
  /// 云后端走 `__local_audio__` 暂存命名空间。
  Future<void> syncLocalAudioSources(
    SyncRunReport report, {
    required SyncAssetDirection direction,
  }) async {
    final SyncBackend b = _backend;
    if (b is InterconnectSyncBackend) {
      await _syncLocalAudioLive(report, b, direction);
      return;
    }
    await syncLocalAudioPackages(report, direction: direction);
  }

  /// Union-syncs local audio source DBs in the `__local_audio__` namespace.
  /// 资产名 = displayName（[LocalAudioDbEntry.path] 含本机时间戳，每机不同不可用）。
  /// push 本地独有（displayName 不在远端）/ pull 远端独有（displayName 不在本地）。
  ///
  /// 已知限制：displayName 无唯一约束，撞名按「同一库」union 跳过（与词典按 name
  /// 同语义）；真正的唯一性去重列为 follow-up。
  Future<void> syncLocalAudioPackages(
    SyncRunReport report, {
    required SyncAssetDirection direction,
  }) async {
    final String ns = await _backend.ensureNamespace(kSyncLocalAudioNamespace);
    final List<AssetEntry> remote = await _backend.listChildren(ns);

    final Set<String> remoteNames = <String>{
      for (final AssetEntry e in remote)
        if (!e.isFolder && _isLocalAudioAsset(e.name))
          _stripLocalAudioAssetSuffix(e.name),
    };
    final Set<String> localNames = <String>{
      for (final LocalAudioDbEntry d in localAudioEntries) d.displayName,
    };

    // Resolve both sides' work first so progress has a real denominator. The
    // push side also drops libraries whose DB file is gone (nothing to send).
    final List<LocalAudioDbEntry> toPush = <LocalAudioDbEntry>[
      if (direction.pushes)
        for (final LocalAudioDbEntry d in localAudioEntries)
          if (!remoteNames.contains(d.displayName) && File(d.path).existsSync())
            d,
    ];
    final List<AssetEntry> toPull = <AssetEntry>[
      if (direction.pulls)
        for (final AssetEntry e in remote)
          if (!e.isFolder &&
              _isLocalAudioAsset(e.name) &&
              !localNames.contains(_stripLocalAudioAssetSuffix(e.name)))
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

  /// Uploads the audiobook package (`audiobook.fushiaudio`) inside each
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
      // sync root and scatter the .fushiaudio package into hibiki-data/ instead
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
        // 先认新名，再回落 Hibiki 时代的旧名：漏认旧名会把「云上已有有声书」
        // 判成没有，于是重新上传一份新名资产，同一本书在云上留下两份包。
        final AssetEntry? existing = await _backend.findAsset(
                folderId, kSyncAudiobookAssetName) ??
            await _backend.findAsset(folderId, kLegacySyncAudiobookAssetName);

        if (hasLocal && existing == null) {
          tmp = _tmpFile('.fushiaudio');
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
  required FushiDatabase db,
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
    // 云后端有声书 pull：下载远端书文件夹时若带 `audiobook.fushiaudio`（push 侧
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

/// 若远端书文件夹 [children] 里存在 `audiobook.fushiaudio`（[kSyncAudiobookAssetName]）
/// 或 Hibiki 时代的 `audiobook.hibikiaudio`（[kLegacySyncAudiobookAssetName]），
/// 下载并用本地刚导入 EPUB 的 [bookKey] 作 `bookKeyOverride` 解包落盘（修复云后端有声书
/// 「只上传拿不回」缺口）。无音频资产是常态（普通书）——静默返回。best-effort：下载/
/// 解包失败仅吞掉（EPUB 已成功导入，不因音频回退整本失败）。
Future<void> _pullRemoteFolderAudiobook({
  required FushiDatabase db,
  required SyncBackend backend,
  required List<AssetEntry> children,
  required String bookKey,
  required Directory audioDatabaseRoot,
  required Directory tempDir,
}) async {
  AssetEntry? audioAsset;
  for (final AssetEntry e in children) {
    if (!e.isFolder &&
        (e.name == kSyncAudiobookAssetName ||
            e.name == kLegacySyncAudiobookAssetName)) {
      audioAsset = e;
      break;
    }
  }
  if (audioAsset == null) return;

  final File tmp = File(p.join(
    tempDir.path,
    'fushi_remote_audio_${DateTime.now().microsecondsSinceEpoch}.fushiaudio',
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
  FushiDatabase db,
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
  FushiDatabase db,
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
  // v82：DB 键 = 书 uid（云端文件夹身份仍是 title 派生 bookKey）。书不在库
  // （wire 有 sidecar 但本地没这本书）安全跳过——沿用「反查不到就不落」语义。
  final EpubBookRow? book = await db.getEpubBook(bookKey);
  if (book == null || book.uid.isEmpty) return;
  final List<({String relativePath, String content, bool deleted})> changed =
      await db.mergeRemoteBookCss(book.uid, remote);
  if (changed.isEmpty) return;
  final String extractDir = book.extractDir;
  if (extractDir.isEmpty) return;
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
