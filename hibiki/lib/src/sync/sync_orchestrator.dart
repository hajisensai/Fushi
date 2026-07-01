import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:hibiki/src/epub/epub_importer.dart';
import 'package:hibiki/src/models/local_audio_manager.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/aggregate_sync_service.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_manager.dart';
import 'package:hibiki/src/sync/sync_progress.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
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

/// True for reserved folder names that are NOT books and must be filtered from
/// any listing of book folders (compare dialog, remote-book import).
bool isReservedSyncFolderName(String name) =>
    name == kSyncDictionaryNamespace ||
    name == kSyncLocalAudioNamespace ||
    name == kSyncAggregateNamespace;

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
  final List<String> errors = <String>[];
  final List<SyncConflict> conflicts = <SyncConflict>[];

  /// True when the run imported data into this device's local library caches or
  /// visible shelves. Export-only runs mutate the remote side and do not need a
  /// local refresh.
  bool get needsLocalLibraryRefresh =>
      booksImported > 0 ||
      dictionariesImported > 0 ||
      audiobooksImported > 0 ||
      localAudioImported > 0;
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

    // 书籍文件开关是上传语义：只把本端已有 epub 内容补到远端。
    // 远端独有书不会在自动同步中导入本机，必须通过 compare/interconnect UI 点击下载。
    final SyncBackend b = _backend;
    final bool isInterconnect = b is HibikiClientSyncBackend;

    if (isInterconnect) {
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

    // 互联（HibikiClientSyncBackend）本地音频 + 有声书包走 live 端点；
    // 云后端仍走原 __local_audio__ 暂存路径（不变）。
    if (isInterconnect) {
      if (syncLocalAudio) await _syncLocalAudioLive(report, b);
      if (syncAudioBookFiles) await _syncAudiobooksLive(report, b);
    } else {
      if (syncLocalAudio) await syncLocalAudioPackages(report);
      if (syncAudioBookFiles) await syncAudiobookPackages(root, report);
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
    }

    // 云后端聚合同步（统计 + 收藏跨端共享，TODO-1056 phase B）。互联 live 端点
    // 是 phase C，这里只做云后端这一条通道，且复用 syncStats 开关（聚合 =
    // 统计 + 收藏，同属「统计同步」语义，不新增设置项 / schema）。
    // deviceId 为空（测试构造 / 未配置）时跳过：聚合快照按 deviceId 命名，无 id
    // 无法安全落每设备快照，降级为 no-op（绝不崩，绝不写错名快照）。
    if (!isInterconnect && syncStats && deviceId.isNotEmpty) {
      await _syncAggregate(report);
    }

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
      report.errors.add('aggregate sync: $e');
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
    final List<DriveFile> remoteFolders = await _backend.listBooks(root);
    final Set<String> localKeys = <String>{
      for (final EpubBookRow b in await _db.getAllEpubBooks())
        sanitizeTtuFilename(b.title),
    };

    // Resolve the remote-only set first so progress has a real denominator.
    final List<DriveFile> toImport = <DriveFile>[
      for (final DriveFile folder in remoteFolders)
        if (!isReservedSyncFolderName(folder.name) &&
            !isReservedSyncFolderName(sanitizeTtuFilename(folder.name)) &&
            !localKeys.contains(sanitizeTtuFilename(folder.name)))
          folder,
    ];
    final int total = toImport.length;

    for (int i = 0; i < total; i++) {
      final DriveFile folder = toImport[i];
      _emit(SyncPhase.books,
          itemIndex: i, itemTotal: total, title: folder.name);
      try {
        if (await importRemoteBookFolder(
          db: _db,
          backend: _backend,
          folderId: folder.id,
          tempDir: _tempDir,
          onProgress: (double f) => _emit(SyncPhase.books,
              itemIndex: i,
              itemTotal: total,
              title: folder.name,
              fileFraction: f),
        )) {
          report.booksImported++;
        }
      } catch (e) {
        report.errors.add('import book "${folder.name}": $e');
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
    HibikiClientSyncBackend backend,
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
        report.errors.add('live push book "$title": $e');
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
    HibikiClientSyncBackend backend,
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
        }
      } catch (e) {
        report.errors.add('live book progress "${book.title}": $e');
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
  /// 每个 uid 的本地进度统一从 prefs（带时间戳）取，并与 `VideoBooks.lastPositionMs`
  /// （旧数据，无独立时间戳记 0）经 [resolveVideoPositionSync] 取较新作为本地真相；
  /// 与 host 进度再比对。胜者新于 host → PUT；胜者不同于本地 → 写回 prefs，**仅当本地
  /// 存在 VideoBooks 行时**才一并更新 `lastPositionMs`（流式视频绝不强建行污染书架）。
  ///
  /// 逐条错误进 [report.errors] 不中断整体。
  Future<void> _syncVideoProgressLive(
    SyncRunReport report,
    HibikiClientSyncBackend backend,
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

    for (final String uid in localUids) {
      final RemoteVideoInfo? hostInfo = hostById[uid];
      if (hostInfo == null) continue; // 本地独有视频：host 无此视频，跳过。
      try {
        await _syncOneVideoProgressLive(
            uid, hostInfo, rowPositionByUid, backend);
      } catch (e) {
        report.errors.add('live video progress "$uid": $e');
      }
    }
  }

  /// 同步单个视频 [uid] 的进度（[_syncVideoProgressLive] 的循环体，控制缩进层数）。
  ///
  /// [rowPositionByUid] 含本地 VideoBooks 行时表示书架视频（写回需更新 lastPositionMs）；
  /// 不含则为流式视频（只写 prefs，不建行）。本地进度统一从 prefs 取并与 lastPositionMs
  /// 经 [resolveVideoPositionSync] 取较新。
  Future<void> _syncOneVideoProgressLive(
    String uid,
    RemoteVideoInfo hostInfo,
    Map<String, int> rowPositionByUid,
    HibikiClientSyncBackend backend,
  ) async {
    // 本地进度真相：书架视频与流式视频共用一个 `_at_` prefs 时间戳。书架视频的位置
    // 在 `VideoBooks.lastPositionMs`（本机播放写），流式视频的位置在
    // `video_remote_position_<uid>` prefs（resume 路径写）——同一进度的两处镜像，不会
    // 同时各有不同含义。本地位置取「有行用 lastPositionMs，否则用 prefs 位置」，时间戳
    // 统一取 `_at_` prefs（无则 0=旧数据，被任何带时间戳的远端进度盖过）。
    final int prefsPos =
        await _db.getPrefTyped<int>(videoRemotePositionPrefKey(uid), 0);
    final int prefsAt =
        await _db.getPrefTyped<int>(videoRemotePositionAtPrefKey(uid), 0);
    final int? rowPos = rowPositionByUid[uid];
    final int localPositionMs = rowPos ?? prefsPos;

    final ({int positionMs, int updatedAtMs}) winner = resolveVideoPositionSync(
      localPositionMs: localPositionMs,
      localUpdatedAtMs: prefsAt,
      remotePositionMs: hostInfo.positionMs,
      remoteUpdatedAtMs: hostInfo.positionUpdatedAtMs,
    );

    // 本地→host：胜者新于 host 时上报（host 端再取较新，幂等安全）。
    if (winner.updatedAtMs > hostInfo.positionUpdatedAtMs ||
        (winner.updatedAtMs == hostInfo.positionUpdatedAtMs &&
            winner.positionMs != hostInfo.positionMs)) {
      await backend.putRemoteVideoPosition(
        uid,
        winner.positionMs,
        winner.updatedAtMs,
      );
    }

    // host→本地：胜者不同于本地时写回。位置真相统一落 `video_remote_position_<uid>`
    // + `_at_` prefs（resume 路径同键空间）；仅当本地存在 VideoBooks 行时一并更新
    // lastPositionMs（流式视频不建行，避免污染书架）。
    if (winner.positionMs != localPositionMs || winner.updatedAtMs != prefsAt) {
      await _db.setPrefTyped<int>(
          videoRemotePositionPrefKey(uid), winner.positionMs);
      await _db.setPrefTyped<int>(
          videoRemotePositionAtPrefKey(uid), winner.updatedAtMs);
      if (rowPos != null) {
        await _db.updateVideoBookPosition(uid, winner.positionMs);
      }
    }
  }

  /// 互联有声书播放进度 live 双向同步（BUG-471）。
  ///
  /// 与视频 [_syncVideoProgressLive] 完全对称。client 听的远端有声书进度落
  /// `audiobook_pos_<bookKey>` + `audiobook_pos_at_<bookKey>` prefs（见
  /// [AudiobookRepository.updatePositionMs]），但互联角色非对称：host 只跑 server，
  /// 从不回灌自己的 `audiobook_pos_` pref，故「立即同步」点了进度不过去（云后端经
  /// SyncManager 双向文件箱正常，互联缺这一段）。
  ///
  /// 同步基底 = 「本地有 `audiobook_pos_<key>` prefs 的 bookKey」∪「本地 Audiobooks
  /// 行的 bookKey」，只对 host 也有的 bookKey 同步（host 无该有声书时其 PUT 端点
  /// 404 / 闸门 no-op，且 GET 无真相可拉，跳过省一次网络）。每个 bookKey 比对本地
  /// prefs 进度与 host 进度，[resolveAudiobookPositionSync]「取较新时间戳」选胜者；
  /// 胜者新于 host → PUT 上报；胜者不同于本地 → 写回本地 prefs。
  ///
  /// 逐条错误进 [report.errors] 不中断整体。
  Future<void> _syncAudiobookProgressLive(
    SyncRunReport report,
    HibikiClientSyncBackend backend,
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

    for (final String bookKey in localKeys) {
      if (!hostKeys.contains(bookKey)) continue; // host 无此有声书：跳过。
      try {
        await _syncOneAudiobookProgressLive(bookKey, backend);
      } catch (e) {
        report.errors.add('live audiobook progress "$bookKey": $e');
      }
    }
  }

  /// 同步单个有声书 [bookKey] 的进度（[_syncAudiobookProgressLive] 的循环体）。
  ///
  /// 本地进度真相 = `audiobook_pos_<bookKey>`（位置）+ `audiobook_pos_at_<bookKey>`
  /// （时间戳，旧数据无记 0）；与 host 进度经 [resolveAudiobookPositionSync] 取较新。
  Future<void> _syncOneAudiobookProgressLive(
    String bookKey,
    HibikiClientSyncBackend backend,
  ) async {
    final int localPos =
        await _db.getPrefTyped<int>(audiobookPositionPrefKey(bookKey), 0);
    final int localAt =
        await _db.getPrefTyped<int>(audiobookPositionAtPrefKey(bookKey), 0);
    final ({int positionMs, int updatedAtMs}) host =
        await backend.remoteAudiobookPosition(bookKey);

    final ({int positionMs, int updatedAtMs}) winner =
        resolveAudiobookPositionSync(
      localPositionMs: localPos,
      localUpdatedAtMs: localAt,
      remotePositionMs: host.positionMs,
      remoteUpdatedAtMs: host.updatedAtMs,
    );

    // 本地→host：胜者新于 host 时上报（host 端再取较新，幂等安全）。
    if (winner.updatedAtMs > host.updatedAtMs ||
        (winner.updatedAtMs == host.updatedAtMs &&
            winner.positionMs != host.positionMs)) {
      await backend.putRemoteAudiobookPosition(
        bookKey,
        winner.positionMs,
        winner.updatedAtMs,
      );
    }

    // host→本地：胜者不同于本地时写回本地 prefs（同 resume/播放写键空间）。
    if (winner.positionMs != localPos || winner.updatedAtMs != localAt) {
      await _db.setPrefTyped<int>(
          audiobookPositionPrefKey(bookKey), winner.positionMs);
      await _db.setPrefTyped<int>(
          audiobookPositionAtPrefKey(bookKey), winner.updatedAtMs);
    }
  }

  /// 测试入口：直接调用 [_syncBookProgressLive]。
  @visibleForTesting
  Future<void> syncBookProgressLiveForTest(
    SyncRunReport report,
    HibikiClientSyncBackend backend,
  ) =>
      _syncBookProgressLive(report, backend);

  /// 测试入口：直接调用 [_syncVideoProgressLive]。
  @visibleForTesting
  Future<void> syncVideoProgressLiveForTest(
    SyncRunReport report,
    HibikiClientSyncBackend backend,
  ) =>
      _syncVideoProgressLive(report, backend);

  /// 测试入口：直接调用 [_syncAudiobookProgressLive]。
  @visibleForTesting
  Future<void> syncAudiobookProgressLiveForTest(
    SyncRunReport report,
    HibikiClientSyncBackend backend,
  ) =>
      _syncAudiobookProgressLive(report, backend);

  /// 测试入口：直接调用 [_syncBooksContentLive]（private 方法对测试文件不可见）。
  @visibleForTesting
  Future<void> syncBooksContentLiveForTest(
    SyncRunReport report,
    HibikiClientSyncBackend backend,
  ) =>
      _syncBooksContentLive(report, backend);

  /// 测试入口：直接调用 [_syncLocalAudioLive]。
  @visibleForTesting
  Future<void> syncLocalAudioLiveForTest(
    SyncRunReport report,
    HibikiClientSyncBackend backend,
  ) =>
      _syncLocalAudioLive(report, backend);

  /// 测试入口：直接调用 [_syncAudiobooksLive]。
  @visibleForTesting
  Future<void> syncAudiobooksLiveForTest(
    SyncRunReport report,
    HibikiClientSyncBackend backend,
  ) =>
      _syncAudiobooksLive(report, backend);

  /// Union-syncs dictionaries. 互联（HibikiClientSyncBackend）→ 直读对端实时库（无暂存）；
  /// 云后端 → 走现有 __dictionaries__ 暂存路径（不变）。无旧设备故无能力探测。
  Future<void> syncDictionaries(SyncRunReport report) async {
    final SyncBackend b = _backend;
    if (b is HibikiClientSyncBackend) {
      await _syncDictionariesLive(report, b);
      return;
    }
    await _syncDictionariesStaged(report);
  }

  /// 互联直读对端实时词典：按名 union，绝不创建/读写 __dictionaries__。
  Future<void> _syncDictionariesLive(
      SyncRunReport report, HibikiClientSyncBackend backend) async {
    final List<DictionaryMetaRow> localDicts =
        await _db.getAllDictionaryMetadata();
    final List<RemoteDictionaryInfo> remoteDicts =
        await backend.listRemoteDictionaries();

    final DictionarySyncDiff diff = computeDictionarySyncDiff(
      localNames: <String>{
        for (final DictionaryMetaRow d in localDicts) d.name
      },
      remoteNames: <String>{
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
        report.errors.add('pull dictionary "$name": $e');
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
        report.errors.add('push dictionary "$name": $e');
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
        report.errors.add('export dictionary "${d.name}": $e');
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
        report.errors.add('import dictionary "${e.name}": $err');
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
    HibikiClientSyncBackend backend,
  ) async {
    final List<RemoteLocalAudioInfo> remoteEntries =
        await backend.listRemoteLocalAudio();
    final Set<String> localNames = <String>{
      for (final LocalAudioDbEntry d in localAudioEntries) d.displayName,
    };
    final Set<String> remoteNames = <String>{
      for (final RemoteLocalAudioInfo r in remoteEntries) r.displayName,
    };

    final LocalAudioSyncDiff diff = computeLocalAudioSyncDiff(
      localNames: localNames,
      remoteNames: remoteNames,
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
        report.errors.add('live pull local audio "$name": $e');
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
        report.errors.add('live push local audio "$name": $e');
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
    HibikiClientSyncBackend backend,
  ) async {
    final List<RemoteAudiobookInfo> remoteAudiobooks =
        await backend.listRemoteAudiobooks();
    final List<AudiobookRow> localAudiobooks = await _db.getAllAudiobooks();
    final List<EpubBookRow> localBooks = await _db.getAllEpubBooks();

    final Set<String> localKeys = <String>{
      for (final AudiobookRow ab in localAudiobooks) ab.bookKey,
    };
    final Set<String> remoteKeys = <String>{
      for (final RemoteAudiobookInfo r in remoteAudiobooks) r.bookKey,
    };
    // 本端已有 EPUB 的 bookKey 集合：Pull 只对「本端有书但缺音频」的远端项动作，
    // 避免落下无 EpubBooks 行可绑的孤儿有声书（importAudioDatabasePackage 不建书行）。
    final Set<String> localBookKeys = <String>{
      for (final EpubBookRow b in localBooks) b.bookKey,
    };

    final AudiobookSyncDiff diff = computeAudiobookSyncDiff(
      localKeys: localKeys,
      remoteKeys: remoteKeys,
    );

    // toPullAudioOnly（场景B 已绿）= 远端有 ∧ 本端无有声书 ∧ 本端已有同 bookKey
    // EPUB → 只补音频不重导 EPUB（走下方现有 pull 循环，逻辑完全不动）。
    final List<String> toPullAudioOnly = <String>[
      for (final String key in diff.toPull)
        if (localBookKeys.contains(key)) key,
    ];

    // toPullFullBook（场景A 新增 TODO-873）= 远端有有声书 ∧ 本端**完全没有这本书**
    // （无 EPUB 行）∧ 远端书有可导出内容（hasContent==true）→ 先拉 EPUB 灌书架、
    // 再拉音频。无内容的远端书跳过（无法导入 EPUB），只能等手动下载。
    //
    // 用 host 书清单解析每本远端书的 hasContent 与原始 title（端点按原始 title
    // 寻址）。按 bookKey 匹配：host 清单条目带真实 bookKey（= EpubBooks PK），
    // 缺省回退 sanitizeTtuFilename(title)（与 host listBooks 同源）。
    final List<RemoteBookInfo> remoteBooks = await backend.listRemoteBooks();
    final Map<String, RemoteBookInfo> remoteBookByKey =
        <String, RemoteBookInfo>{
      for (final RemoteBookInfo r in remoteBooks)
        (r.bookKey ?? sanitizeTtuFilename(r.title)): r,
    };
    final List<({String audiobookKey, String title})> toPullFullBook =
        <({String audiobookKey, String title})>[
      for (final String key in diff.toPull)
        if (!localBookKeys.contains(key))
          if (remoteBookByKey[key] case final RemoteBookInfo book
              when book.hasContent)
            (audiobookKey: key, title: book.title),
    ];

    final int total =
        diff.toPush.length + toPullAudioOnly.length + toPullFullBook.length;
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
        report.errors.add('live push audiobook "$key": $e');
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
        report.errors.add('live pull audiobook "$key": $e');
      } finally {
        _safeDelete(tmp);
      }
      index++;
    }

    // ── Pull B（场景A · TODO-873）：远端-only 带有声书的书 → 先拉 EPUB 灌书架、
    // 再拉音频。配对纪律见 [_pullRemoteOnlyAudiobook]（BUG-414）。──────────────
    for (final ({String audiobookKey, String title}) item in toPullFullBook) {
      _emit(SyncPhase.audiobooks,
          itemIndex: index, itemTotal: total, title: item.title);
      await _pullRemoteOnlyAudiobook(
        backend,
        item.title,
        item.audiobookKey,
        report,
      );
      index++;
    }
  }

  /// 拉取一本「远端-only 带有声书」的书：先拉 EPUB 灌本地书架，再用本地新 EPUB 的
  /// bookKey 绑定拉音频包（TODO-873）。
  ///
  /// **BUG-414 配对纪律**：
  /// - EPUB 用 [HibikiClientSyncBackend.getRemoteBook]（端点按原始 [title] 寻址）下载，
  ///   经 [EpubImporter.importFromPath] 导入，返回值即本地新 `localBookKey`（=
  ///   `sanitizeTtuFilename(storedTitle)`，本地唯一）。
  /// - 音频用 host 清单里该书的真实 [remoteAudiobookKey] 下载（**不重算**
  ///   `sanitizeTtuFilename(title)`），解包时 `bookKeyOverride: localBookKey` 绑定到
  ///   本地刚导入的 EPUB，保证写入的 Audiobooks 行与本地 EPUB 行 bookKey 相等（书架
  ///   类型徽章亮，否则退化为普通书）。
  ///
  /// 逐项 try/catch 进 [report.errors] 不中断整体；临时文件 finally 清理。
  Future<void> _pullRemoteOnlyAudiobook(
    HibikiClientSyncBackend backend,
    String title,
    String remoteAudiobookKey,
    SyncRunReport report,
  ) async {
    File? epubTmp;
    File? audioTmp;
    try {
      // ① 拉 EPUB → 导入书架，拿本地新 bookKey。
      epubTmp = _tmpFile('.epub');
      await backend.getRemoteBook(title, epubTmp);
      final String localBookKey = await EpubImporter.importFromPath(
        db: _db,
        filePath: epubTmp.path,
        fileName: '$title.epub',
      );
      report.booksImported++;

      // ② 拉音频包 → 解包，bookKeyOverride 绑定本地 EPUB bookKey（徽章配对）。
      audioTmp = _tmpFile('.hibikiaudio');
      await backend.getRemoteAudiobook(remoteAudiobookKey, audioTmp);
      await _packages.importAudioDatabasePackage(
        packageFile: audioTmp,
        audioDatabaseRoot: _audioDatabaseRoot,
        bookKeyOverride: localBookKey,
      );
      report.audiobooksImported++;
    } catch (e) {
      report.errors.add('live pull remote-only audiobook "$title": $e');
    } finally {
      _safeDelete(epubTmp);
      _safeDelete(audioTmp);
    }
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
        report.errors.add('export local audio "${d.displayName}": $e');
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
        report.errors.add('import local audio "${e.name}": $err');
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
        report.errors.add('audiobook "${book.title}": $e');
      } finally {
        _safeDelete(tmp);
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
    await EpubImporter.importFromPath(
      db: db,
      filePath: tmp.path,
      fileName: epub.name,
    );
    return true;
  } finally {
    try {
      if (tmp.existsSync()) tmp.deleteSync();
    } catch (_) {
      // best-effort temp cleanup
    }
  }
}
