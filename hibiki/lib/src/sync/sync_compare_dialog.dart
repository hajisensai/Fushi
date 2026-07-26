import 'dart:developer' as developer;
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:hibiki/src/epub/book_title_conflict.dart';
import 'package:hibiki/src/epub/epub_importer.dart';
import 'package:hibiki/src/media/video/video_import_dialog.dart'
    show parseSubtitleCues;
import 'package:hibiki/src/models/local_audio_manager.dart';
import 'package:hibiki/src/storage/app_paths.dart';
import 'package:hibiki/src/sync/cloud_remote_video_client.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/sync_compare_assets.dart';
import 'package:hibiki/src/sync/position_converter.dart';
import 'package:hibiki/src/sync/sync_auto_trigger.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_error_messages.dart';
import 'package:hibiki/src/sync/sync_manager.dart';
import 'package:hibiki/src/sync/sync_message_dialog.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/sync_progress_resolver.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/sync_utils.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki/src/sync/video_manifest.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki_audio/hibiki_audio.dart'
    show AudioCue, readTextWithEncoding;
import 'package:path/path.dart' as p;

enum SyncChoice { skip, useLocal, useRemote }

class SyncCompareEntry {
  SyncCompareEntry({
    required this.title,
    required this.bookKey,
    this.remoteFolderId,
    this.remoteLiveTitle,
    this.remoteHasContent = true,
    this.remoteAudioBookId,
    this.localProgress,
    this.localUpdatedAt,
    this.remoteProgress,
    this.remoteUpdatedAt,
    this.localStatsCount,
    this.remoteStatsCount,
    this.localAudioPosMs,
    this.remoteAudioPosSec,
    this.base,
  });

  final String title;
  final String? bookKey;

  /// 远端书籍文件夹的原生定位符（删除整本远端书用）；本端独有书为 null。
  final String? remoteFolderId;

  /// Hibiki 互联 live library 里的书名。它没有 WebDAV 书文件夹，下载必须走
  /// `/api/library/books/<title>`，不能交给 [importRemoteBookFolder]。
  final String? remoteLiveTitle;

  /// 该远端文件夹是否含可下载的 `.epub` 内容。仅对「远端独有」书有意义：为 false
  /// 时是只剩同步元数据的孤儿，不能当可下载书（避免 BUG-049 幽灵下载），但条目保留
  /// 以便删除。本端已有书 / 本端独有书恒为 true（不参与远端下载判定）。
  final bool remoteHasContent;

  /// 远端独有且确有内容可下载（[remoteFolderId] 非空且 [remoteHasContent]）。
  bool get isDownloadableRemoteOnly =>
      bookKey == null &&
      (remoteFolderId != null || remoteLiveTitle != null) &&
      remoteHasContent;

  /// 远端有声书资产（audiobook.hibikiaudio）的原生定位符；无远端有声书为 null。
  final String? remoteAudioBookId;

  final double? localProgress;
  final int? localUpdatedAt;
  final double? remoteProgress;
  final int? remoteUpdatedAt;
  final int? localStatsCount;
  final int? remoteStatsCount;
  final int? localAudioPosMs;
  final double? remoteAudioPosSec;

  /// 共同祖先基线（progress 维度时间戳）；用于把「时间戳不等」收紧为「真分叉」。
  final int? base;

  bool get hasLocal => localUpdatedAt != null;
  bool get hasRemote => remoteUpdatedAt != null;

  /// 冲突 = 双边都偏离共同祖先 base（真分叉），不再是简单的时间戳不等。
  /// 单边改动（一边等于 base）由 [resolveProgressSync] 判为自动方向，不算冲突。
  bool get hasConflict => resolveProgressSync(
        local: localUpdatedAt,
        remote: remoteUpdatedAt,
        base: base,
      ).isConflict;
  bool get isSynced =>
      hasLocal && hasRemote && localUpdatedAt == remoteUpdatedAt;
  bool get needsManualChoice => hasConflict;

  SyncDirection get autoDirection {
    if (!hasLocal && !hasRemote) return SyncDirection.synced;
    if (!hasLocal) return SyncDirection.importFromTtu;
    if (!hasRemote) return SyncDirection.exportToTtu;
    if (localUpdatedAt! > remoteUpdatedAt!) return SyncDirection.exportToTtu;
    if (remoteUpdatedAt! > localUpdatedAt!) return SyncDirection.importFromTtu;
    return SyncDirection.synced;
  }
}

/// [_fetchCompareData] 的产物：书籍对比行 + 云后端在本轮扫描中顺带拿到的有声书
/// 资产定位符（书名 -> assetId）。后者交给 [fetchSyncAssetEntries] 复用，避免为
/// 「远端有没有有声书」再列一遍远端。
class _CompareData {
  const _CompareData(this.entries, this.cloudAudiobookIds);
  final List<SyncCompareEntry> entries;
  final Map<String, String> cloudAudiobookIds;
}

/// Test seam for [_fetchCompareData] (the production builder is private).
@visibleForTesting
Future<List<SyncCompareEntry>> fetchCompareDataForTest(
  HibikiDatabase db,
  SyncBackend backend,
) async =>
    (await _fetchCompareData(db, backend)).entries;

Future<_CompareData> _fetchCompareData(
  HibikiDatabase db,
  SyncBackend backend,
) async {
  final repo = SyncRepository(db);

  // 本地快照与互联 live 清单彼此独立，和 root/listBooks 同时起跑；旧实现把这些
  // await 串成 7 段，即便每段已是批量查询，墙钟时间仍是全部 RTT/DB 查询之和。
  final Future<List<RemoteBookInfo>> liveBooksFuture =
      backend is HibikiClientSyncBackend
          ? backend.listRemoteBooks()
          : Future<List<RemoteBookInfo>>.value(const <RemoteBookInfo>[]);
  final localBooksFuture = db.getAllEpubBooks();
  final allStatsFuture = db.getAllReadingStatistics();
  final positionsFuture = db.getAllReaderPositions();
  final audioPositionsFuture = repo.getAllAudiobookPositions();
  final baselinesFuture = db.getSyncBaselinesByDimension('progress');

  final rootId = await _ensureRoot(backend, repo);
  // Reserved asset namespaces (e.g. __dictionaries__) live alongside book
  // folders under the root; they are not books and must not appear as phantom
  // compare entries.
  final remoteBooks = (await backend.listBooks(rootId))
      .where((DriveFile f) => !isReservedSyncFolderName(f.name))
      .toList();
  backend.cacheBookFolderIds(remoteBooks);
  final List<RemoteBookInfo> liveBooks = await liveBooksFuture;
  final localBooks = await localBooksFuture;

  final allTitles = <String>{};
  final localByTitle = <String, EpubBookRow>{};
  for (final b in localBooks) {
    localByTitle[b.title] = b;
    allTitles.add(b.title);
  }

  final remoteByTitle = <String, DriveFile>{};
  for (final f in remoteBooks) {
    remoteByTitle[f.name] = f;
    final cleaned = _unsanitize(f.name);
    if (cleaned != f.name) remoteByTitle[cleaned] = f;
    allTitles.add(cleaned);
  }
  final liveByTitle = <String, RemoteBookInfo>{};
  for (final RemoteBookInfo book in liveBooks) {
    liveByTitle[book.title] = book;
    allTitles.add(book.title);
  }

  final allStats = await allStatsFuture;
  final statCountByTitle = <String, int>{};
  for (final r in allStats) {
    statCountByTitle[r.title] = (statCountByTitle[r.title] ?? 0) + 1;
  }

  // 三张按书查的表一次取回（bookKey/assetKey -> 值）。此前是在下面的 per-title
  // 循环里逐本 await —— N 本书就是 3N 次串行查询，书一多就主导整个加载耗时。
  final Map<String, ReaderPositionRow> positionByKey =
      <String, ReaderPositionRow>{
    for (final ReaderPositionRow p in await positionsFuture) p.bookKey: p,
  };
  final Map<String, int> audioPosByKey = await audioPositionsFuture;
  final Map<String, int> baselineByAssetKey = await baselinesFuture;

  // Fetch remote data in parallel batches to avoid Drive API rate limits
  final remoteDataMap = <String, _RemoteBookData>{};
  final remoteJobs = <MapEntry<String, String>>[];
  final Set<String> remoteJobTitles = <String>{};
  for (final title in allTitles) {
    final sanitized = sanitizeTtuFilename(title);
    final remote = remoteByTitle[title] ?? remoteByTitle[sanitized];
    if (remote != null && remoteJobTitles.add(title)) {
      remoteJobs.add(MapEntry(title, remote.id));
    }
  }
  const batchSize = 5;
  for (var i = 0; i < remoteJobs.length; i += batchSize) {
    final batch = remoteJobs.skip(i).take(batchSize).toList();
    final results = await Future.wait(
      batch.map((e) => _fetchRemoteBookData(backend, e.value)),
    );
    for (var j = 0; j < batch.length; j++) {
      remoteDataMap[batch[j].key] = results[j];
    }
  }

  final entries = <SyncCompareEntry>[];
  final Map<String, String> cloudAudiobookIds = <String, String>{};

  for (final title in allTitles) {
    final local = localByTitle[title];

    double? localProg;
    int? localUpdatedAt;
    int? localStatsCount;
    int? localAudioMs;

    if (local != null) {
      try {
        final pos = positionByKey[local.bookKey];
        if (pos != null) {
          final chapters = parseChaptersJson(local.chaptersJson);
          final total = totalCharacterCount(chapters);
          final explored = toExploredCharCount(
            sectionIndex: pos.sectionIndex,
            normCharOffset: pos.normCharOffset,
            chapters: chapters,
          );
          localProg = total > 0 ? explored / total : 0;
          localUpdatedAt = pos.updatedAt;
        }
        localStatsCount = statCountByTitle[title];
        localAudioMs = audioPosByKey[local.bookKey];
      } catch (e) {
        developer.log(
          'Failed to parse local data for "$title"',
          error: e,
          name: 'SyncCompare',
        );
      }
    }

    final remoteData = remoteDataMap[title];
    final remote =
        remoteByTitle[title] ?? remoteByTitle[sanitizeTtuFilename(title)];
    final live = liveByTitle[title];

    // Whether this remote book folder actually holds downloadable book content.
    // Only meaningful (and only checked, to save a round-trip) for remote-only
    // books: a folder with no local book and no .epub is an orphan that holds
    // only sync metadata, so it must NOT be offered as a download that
    // importRemoteBookFolder can never satisfy — the phantom "download" row
    // that never clears (BUG-049). The row is still kept so it can be deleted.
    final bool remoteHasContent = local == null
        ? (remote != null
            ? (remoteData?.hasContent ?? true)
            : (live?.hasContent ?? true))
        : true;

    // 跨设备资产身份与 SyncManager 一致：sanitizeTtuFilename(title)。读共同祖先
    // 基线，让「时间戳不等」收紧为「真分叉」冲突判定。
    final int? base = baselineByAssetKey[sanitizeTtuFilename(title)];

    // 云后端的有声书包就藏在书文件夹里，本轮已经列到了；记下来交给资产维度复用。
    final String? audioId = remoteData?.audioBookId;
    if (audioId != null) cloudAudiobookIds[title] = audioId;

    entries.add(SyncCompareEntry(
      title: title,
      bookKey: local?.bookKey,
      remoteFolderId: remote?.id,
      remoteLiveTitle: live?.title,
      remoteHasContent: remoteHasContent,
      remoteAudioBookId: remoteData?.audioBookId,
      localProgress: localProg,
      localUpdatedAt: localUpdatedAt,
      remoteProgress: remoteData?.progress,
      remoteUpdatedAt: remoteData?.updatedAt,
      localStatsCount: localStatsCount,
      remoteStatsCount: remoteData?.statsCount,
      localAudioPosMs: localAudioMs,
      remoteAudioPosSec: remoteData?.audioPosSec,
      base: base,
    ));
  }

  final rootIdNow = backend.cachedRootFolderId;
  if (rootIdNow != null) await repo.setRootFolderId(rootIdNow);
  final cache = backend.cachedFolderIds;
  if (cache.isNotEmpty) await repo.setFolderCache(cache);

  return _CompareData(entries, cloudAudiobookIds);
}

/// 资产维度（词典/有声书/音频数据库/视频）的取数 + 门控。
///
/// 门控只作用于**纯本地词典**：远端项始终保留（要能删它），本地独有词典只在词典
/// 同步开着时才列，避免关掉该选项时用一屏无关本地词典刷屏。其余三类不设此门——
/// 「本端有、远端没有」正是用户要看见并决定上不上传的东西，藏起来就等于没这功能。
Future<List<SyncAssetEntry>> _fetchAssetEntries(
  HibikiDatabase db,
  SyncBackend backend, {
  required bool includeLocalOnlyDicts,
  required List<LocalAudioDbEntry> localAudioEntries,
  Future<Map<String, String>>? cloudAudiobookIds,
  void Function(String dimension, Object error)? onError,
}) async {
  final List<SyncAssetEntry> out = await fetchSyncAssetEntries(
    db: db,
    backend: backend,
    localAudioEntries: localAudioEntries,
    cloudAudiobookIds: cloudAudiobookIds,
    onError: onError,
  );
  out.removeWhere((SyncAssetEntry e) =>
      e.kind == SyncAssetKind.dictionary &&
      !e.hasRemote &&
      !includeLocalOnlyDicts);
  return out;
}

class _RemoteBookData {
  const _RemoteBookData({
    this.progress,
    this.updatedAt,
    this.statsCount,
    this.audioPosSec,
    this.audioBookId,
    this.hasContent = false,
  });

  final double? progress;
  final int? updatedAt;
  final int? statsCount;
  final double? audioPosSec;

  /// 远端有声书资产（audiobook.hibikiaudio）的原生定位符；无则 null。
  final String? audioBookId;

  /// 同一次目录列举中是否发现可下载的 EPUB 内容。
  final bool hasContent;
}

Future<_RemoteBookData> _fetchRemoteBookData(
  SyncBackend backend,
  String folderId,
) async {
  try {
    // 一次目录列举同时识别 TTU 元数据、EPUB 与真实有声书包。旧实现先
    // listSyncFiles（内部就是一次 listing），再 listChildren 探 EPUB/包，远端每本书
    // 固定两次 RTT。`audioBook_1_6_*.json` 仍只用于播放位置，绝不当有声书包。
    final List<AssetEntry> children = await backend.listChildren(folderId);
    final List<DriveFile> files = <DriveFile>[
      for (final AssetEntry child in children)
        if (!child.isFolder) DriveFile(id: child.id, name: child.name),
    ];
    final DriveSyncFiles syncFiles = DriveSyncFiles(
      progress: findSyncFileByPrefix(files, 'progress_'),
      statistics: findSyncFileByPrefix(files, 'statistics_'),
      audioBook: findSyncFileByPrefix(files, 'audioBook_'),
    );

    double? progress;
    int? updatedAt;
    int? statsCount;
    double? audioPosSec;
    String? audioBookId;
    bool hasContent = false;

    for (final AssetEntry child in children) {
      if (child.isFolder) continue;
      if (child.name == kSyncAudiobookAssetName) {
        audioBookId = child.id;
      }
      if (child.name.toLowerCase().endsWith('.epub')) {
        hasContent = true;
      }
    }

    final futures = <Future<void>>[];

    if (syncFiles.progress != null) {
      futures.add(backend.getProgressFile(syncFiles.progress!.id).then((p) {
        progress = p.progress;
        updatedAt = p.lastBookmarkModified;
      }));
    }
    if (syncFiles.statistics != null) {
      futures.add(backend.getStatsFile(syncFiles.statistics!.id).then((s) {
        statsCount = s.length;
      }));
    }
    if (syncFiles.audioBook != null) {
      futures.add(backend.getAudioBookFile(syncFiles.audioBook!.id).then((a) {
        audioPosSec = a.playbackPositionSec;
      }));
    }

    await Future.wait(futures);

    return _RemoteBookData(
      progress: progress,
      updatedAt: updatedAt,
      statsCount: statsCount,
      audioPosSec: audioPosSec,
      audioBookId: audioBookId,
      hasContent: hasContent,
    );
  } catch (e) {
    developer.log(
      'Failed to fetch remote data for folder $folderId',
      error: e,
      name: 'SyncCompare',
    );
    return const _RemoteBookData();
  }
}

Future<String> _ensureRoot(
  SyncBackend backend,
  SyncRepository repo,
) async {
  if (backend.cachedRootFolderId != null) return backend.cachedRootFolderId!;
  final savedRoot = await repo.getRootFolderId();
  final savedCache = await repo.getFolderCache();
  backend.restoreCache(rootFolderId: savedRoot, titleToFolderId: savedCache);
  return backend.findOrCreateRootFolder();
}

String _unsanitize(String name) {
  return name
      .replaceAll('~ttu-spc~', ' ')
      .replaceAll('~ttu-dend~', '.')
      .replaceAll('~ttu-star~', '*')
      .replaceAllMapped(
        RegExp(r'%([0-9A-Fa-f]{2})'),
        (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)),
      );
}

Future<void> showSyncCompareDialog(
  BuildContext context,
  HibikiDatabase db, {
  bool conflictsOnly = false,
  Directory? tempDir,
  Directory? audioDatabaseRoot,
  List<LocalAudioDbEntry> localAudioEntries = const <LocalAudioDbEntry>[],
  Directory? dictionaryResourceRoot,
  Future<void> Function(LocalAudioPackageContents)? onLocalAudioImported,
}) async {
  final repo = SyncRepository(db);
  final backend = resolveSyncBackend(await repo.getBackendType());
  // Rehydrate the saved session first — opening compare straight after a cold
  // start would otherwise read a not-yet-restored auth state and wrongly report
  // "set up sync first" (mobile google_sign_in / desktop refresh) (BUG-047).
  // Do it under the sync mutex so the auth restore (which can reconnect/clear a
  // backend's cache) never races an in-flight sync (BUG-083).
  final bool authed = await runExclusiveWithSync(() async {
    await backend.restoreAuth(repo);
    return backend.isAuthenticated;
  });
  if (!authed) {
    if (!context.mounted) return;
    // The compare precondition is "a sync target is configured" — not an
    // account login. The Hibiki interconnect (and WebDAV/FTP/SFTP) have no
    // sign-in, so "not signed in" was wrong there; use a backend-neutral
    // "set up sync first" message that reads correctly for every backend.
    showSyncMessage(context, t.sync_compare_unavailable);
    return;
  }

  if (!context.mounted) return;

  final applied = await showAppDialog<int>(
    context: context,
    barrierDismissible: false,
    builder: (_) => SyncCompareDialog(
      db: db,
      backend: backend,
      conflictsOnly: conflictsOnly,
      tempDir: tempDir,
      audioDatabaseRoot: audioDatabaseRoot,
      localAudioEntries: localAudioEntries,
      dictionaryResourceRoot: dictionaryResourceRoot,
      onLocalAudioImported: onLocalAudioImported,
    ),
  );
  if (applied != null && applied > 0 && context.mounted) {
    showSyncMessage(context, t.sync_compare_applied(count: applied));
  }
}

/// 同步对比对话框：列出本端/远端书籍、词典差异并支持逐行删除远端副本。
///
/// 构造直接注入 [backend]，因此天生可测——widget 测试可注入 fake backend 直接
/// `pumpWidget` 它，无需走 [showSyncCompareDialog] 的解析/导航路径。生产入口仍是
/// [showSyncCompareDialog]。
@visibleForTesting
class SyncCompareDialog extends StatefulWidget {
  const SyncCompareDialog({
    required this.db,
    required this.backend,
    this.conflictsOnly = false,
    this.tempDir,
    this.audioDatabaseRoot,
    this.localAudioEntries = const <LocalAudioDbEntry>[],
    this.dictionaryResourceRoot,
    this.onLocalAudioImported,
    super.key,
  });
  final HibikiDatabase db;
  final SyncBackend backend;

  /// 本机已注册的音频数据库（本地音频来源）。同步层不依赖 AppModel，故与
  /// [SyncOrchestrator.localAudioEntries] 同律由调用方注入；默认空表 = 不列该维度。
  final List<LocalAudioDbEntry> localAudioEntries;

  /// 词典资源根；词典行的上传/下载要用（打包/解包词典资源）。null = 词典行不提供
  /// 传输动作（仍可显示与删除远端）。
  final Directory? dictionaryResourceRoot;

  /// 拉到远端音频数据库包后的注册回调（[AppModel.importSyncedLocalAudioDb]）。
  /// null = 音频数据库行不提供下载动作（拉下来没人注册，等于白下）。
  final Future<void> Function(LocalAudioPackageContents)? onLocalAudioImported;

  /// 只显示真分叉冲突项（隐藏自动可解的书与词典分组）。冲突解决弹窗用。
  final bool conflictsOnly;

  /// 下载远端独有书时的临时目录；为 null 时落回系统临时目录。
  final Directory? tempDir;

  /// 有声书解包落盘根目录（`<appDirectory>/audiobooks`）。下载远端独有书时若该书
  /// 带有声书，据此一并补下音频包（750a）。为 null 时跳过有声书补下（仅导 EPUB），
  /// 保留旧行为，供不关心有声书的测试构造。
  final Directory? audioDatabaseRoot;

  @override
  State<SyncCompareDialog> createState() => _SyncCompareDialogState();
}

class _SyncCompareDialogState extends State<SyncCompareDialog> {
  List<SyncCompareEntry>? _entries;
  List<SyncAssetEntry>? _assets;
  Map<String, SyncChoice> _choices = {};
  String? _error;
  bool _applying = false;
  double? _progress;
  String? _progressLabel;
  List<String> _assetErrors = const <String>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 解析下载用临时目录：优先注入值，否则系统临时目录。
  Directory _resolveTempDir() => widget.tempDir ?? Directory.systemTemp;

  Future<void> _load() async {
    try {
      _error = null;
      final repo = SyncRepository(widget.db);
      final bool dictSyncOn = await repo.isSyncDictionaryEnabled();
      final List<String> assetErrors = <String>[];
      // Fetch the remote listing under the sync mutex: this re-lists the remote
      // and rewrites the singleton backend's folder-id cache, so running it
      // concurrently with an in-flight sync corrupted the sync's view and made
      // this load contend on the same connection (slow / timeout) (BUG-083).
      final (List<SyncCompareEntry> entries, List<SyncAssetEntry> assets) =
          await runExclusiveWithSync(() async {
        // 书籍与四类资产的远端列举彼此独立，一起发出去：加维度不加墙钟时间。
        // 云有声书那一维需要书籍这一轮顺带拿到的 assetId，故把它作为 Future 递进
        // 去——只有有声书那一支真正等它，其余三支照跑。
        final Future<_CompareData> books =
            _fetchCompareData(widget.db, widget.backend);
        final Future<List<SyncAssetEntry>> assetsFuture = widget.conflictsOnly
            ? Future<List<SyncAssetEntry>>.value(const <SyncAssetEntry>[])
            : _fetchAssetEntries(
                widget.db,
                widget.backend,
                includeLocalOnlyDicts: dictSyncOn,
                localAudioEntries: widget.localAudioEntries,
                cloudAudiobookIds:
                    books.then((_CompareData d) => d.cloudAudiobookIds),
                onError: (String dimension, Object error) {
                  assetErrors.add('$dimension: ${friendlySyncError(error)}');
                },
              );
        return ((await books).entries, await assetsFuture);
      });
      final choices = <String, SyncChoice>{};
      for (final e in entries) {
        if (e.bookKey == null) {
          // remote-only 书改成行内点击下载，不再默认纳入 Apply 批量对账。
          // 只剩同步元数据的孤儿也保持 skip，避免无法完成的幽灵下载（BUG-049）。
          choices[e.title] = SyncChoice.skip;
        } else if (e.isSynced) {
          choices[e.title] = SyncChoice.skip;
        } else if (e.autoDirection == SyncDirection.importFromTtu) {
          choices[e.title] = SyncChoice.useRemote;
        } else if (e.autoDirection == SyncDirection.exportToTtu) {
          choices[e.title] = SyncChoice.useLocal;
        } else {
          choices[e.title] = SyncChoice.skip;
        }
      }
      if (mounted) {
        setState(() {
          _entries = entries;
          _assets = assets;
          _choices = choices;
          _assetErrors = assetErrors;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = friendlySyncError(e));
    }
  }

  /// 单一真相源：哪些 entries 参与渲染/计数/Apply。
  ///
  /// conflictsOnly 模式下（冲突解决弹窗）只有真分叉冲突项参与——非冲突书既不显示
  /// 也不会被 Apply 同步，消除「渲染集 vs 应用集」漂移。默认（false）路径逐字节不变。
  List<SyncCompareEntry> get _entriesInPlay {
    final entries = _entries;
    if (entries == null) return const <SyncCompareEntry>[];
    if (!widget.conflictsOnly) return entries;
    return entries.where((e) => e.hasConflict).toList();
  }

  /// 一条 entry 是否参与 Apply：选了非 skip，且要么本地已有（bookId，做进度同步），
  /// 要么远端独有且确有内容可下载（[isDownloadableRemoteOnly]）。只剩同步元数据的
  /// 远端孤儿不可下载，故不参与 Apply（仍可经行内删除清理）（BUG-049）。
  bool _isActionable(SyncCompareEntry e) {
    final c = _choices[e.title];
    if (c == null || c == SyncChoice.skip) return false;
    return e.bookKey != null;
  }

  Future<void> _applyChoices() async {
    if (_entries == null) return;
    final entries = _entriesInPlay;

    // Only the books the user chose to sync count toward progress.
    final actionable = entries.where(_isActionable).toList();
    final total = actionable.length;

    setState(() {
      _applying = true;
      _progress = total == 0 ? null : 0.0;
      _progressLabel = null;
    });
    try {
      // Apply runs real network writes (downloads/uploads/deletes) on the shared
      // singleton backend, so it must be serialized against any in-flight sync —
      // same contention that interrupted sync and timed out the load (BUG-083).
      await runExclusiveWithSync(() async {
        final repo = SyncRepository(widget.db);
        final syncStats = await repo.isSyncStatsEnabled();
        final syncAudioBook = await repo.isSyncAudioBookEnabled();
        // BUG-988：手动解决冲突并应用时，互联通道读互联专属上传开关、云通道读共享开关，
        // 与自动同步一致——否则「互联内容开、云内容关」时互联冲突的内容传输会被误跳过。
        final syncContent = widget.backend is HibikiClientSyncBackend
            ? await repo.isInterconnectSyncContentEnabled()
            : await repo.isSyncContentEnabled();

        var done = 0;
        // Blend per-file transfer fraction into the overall book progress so the
        // bar advances smoothly during large content downloads/uploads.
        final manager = SyncManager(
          db: widget.db,
          backend: widget.backend,
          onContentProgress: (fraction) {
            if (mounted && total > 0) {
              setState(
                  () => _progress = (done + fraction.clamp(0.0, 1.0)) / total);
            }
          },
        );

        int applied = 0;
        final errors = <String>[];
        for (final entry in actionable) {
          final choice = _choices[entry.title]!;

          if (entry.bookKey == null) {
            // remote-only：下载并导入本地（显式用户动作，不受 syncContent 门控）。
            if (mounted) {
              setState(() {
                _progressLabel = '(${done + 1}/$total) ${entry.title}';
                _progress = done / total;
              });
            }
            try {
              final bool imported = await importRemoteBookFolder(
                db: widget.db,
                backend: widget.backend,
                folderId: entry.remoteFolderId!,
                tempDir: _resolveTempDir(),
              );
              if (imported) applied++;
            } on DuplicateImportCancelledException {
              // 良性：本机已有同名书，跳过。
            } catch (e) {
              errors.add(entry.title);
              developer.log(
                'Failed to download "${entry.title}"',
                error: e,
                name: 'SyncCompare',
              );
            }
            done++;
            if (mounted) setState(() => _progress = done / total);
            continue;
          }

          final book = await widget.db.getEpubBook(entry.bookKey!);
          if (book == null) {
            done++;
            continue;
          }

          if (mounted) {
            setState(() {
              _progressLabel = '(${done + 1}/$total) ${entry.title}';
              _progress = done / total;
            });
          }

          final direction = choice == SyncChoice.useLocal
              ? SyncDirection.exportToTtu
              : SyncDirection.importFromTtu;

          try {
            final result = await manager.syncBook(
              book: book,
              direction: direction,
              syncStats: syncStats,
              statsSyncMode: StatisticsSyncMode.merge,
              syncAudioBook: syncAudioBook,
              syncContent: syncContent,
            );
            switch (classifySyncApply(result)) {
              case SyncApplyOutcome.applied:
                applied++;
              case SyncApplyOutcome.failed:
                errors.add(entry.title);
              case SyncApplyOutcome.noop:
                // 良性跳过（无可传输内容）：既不计成功也不报错，避免误报「同步错误」。
                break;
            }
          } catch (e) {
            errors.add(entry.title);
            developer.log(
              'Failed to sync "${entry.title}"',
              error: e,
              name: 'SyncCompare',
            );
          }
          done++;
          if (mounted) setState(() => _progress = done / total);
        }

        if (mounted) {
          if (errors.isNotEmpty) {
            showSyncMessage(
              context,
              t.sync_error(message: errors.join(', ')),
            );
          }
          Navigator.pop(context, applied);
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _applying = false;
          _error = friendlySyncError(e);
        });
      }
    }
  }

  /// 750a：互联下载远端独有书时补下其有声书包（若有）。
  ///
  /// 远端有声书键 = host 清单里该书的真实 [RemoteAudiobookInfo.bookKey]（按
  /// `title == entry.title` 匹配），不再按书名重算 ttu 文件名：书名重名/迁移时算出
  /// 的 key 在 host `Audiobooks` 表不存在会 404（BUG-414）。先查
  /// host 有声书清单确认存在（避免对没声书的书发无意义请求），再下载 `.hibikiaudio` 经
  /// [SyncAssetPackageService.importAudioDatabasePackage] 用本地 [localBookKey] 作
  /// `bookKeyOverride` 解包落盘。[audioDatabaseRoot] 为 null（调用方未注入根目录）
  /// 时跳过有声书补下，只保留 EPUB（旧行为）。
  Future<void> _downloadLiveAudiobookFor(
    HibikiClientSyncBackend backend,
    SyncCompareEntry entry,
    String localBookKey,
  ) async {
    final Directory? audioRoot = widget.audioDatabaseRoot;
    if (audioRoot == null) return;

    final List<RemoteAudiobookInfo> remote =
        await backend.listRemoteAudiobooks();
    // host 清单条目带真实 bookKey（= Audiobooks.bookKey）+ title（= srt.title）。
    // 按 title 找到该书，用其真实 bookKey 下载——不要按书名重算 ttu 文件名（BUG-414）。
    String? remoteBookKey;
    for (final RemoteAudiobookInfo a in remote) {
      // 只匹配 srt-backed（bookKey 非空）：本函数是给 EPUB 书补音频，纯 SRT
      // standalone 项（bookKey 空、身份=uid）不参与，避免同名误匹配到空 bookKey。
      if (a.bookKey.isNotEmpty && a.title == entry.title) {
        remoteBookKey = a.bookKey;
        break;
      }
    }
    if (remoteBookKey == null) return;

    final Directory dir = _resolveTempDir();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final File audioTmp = File(
      p.join(
        dir.path,
        'hibiki-compare-audio-'
        '${DateTime.now().microsecondsSinceEpoch}.hibikiaudio',
      ),
    );
    try {
      await backend.getRemoteAudiobook(remoteBookKey, audioTmp);
      await SyncAssetPackageService(db: widget.db).importAudioDatabasePackage(
        packageFile: audioTmp,
        audioDatabaseRoot: audioRoot,
        bookKeyOverride: localBookKey,
      );
    } finally {
      try {
        if (audioTmp.existsSync()) audioTmp.deleteSync();
      } catch (_) {
        // best-effort temp cleanup
      }
    }
  }

  Future<bool> _downloadRemoteOnlyBook(SyncCompareEntry entry) async {
    if (!entry.isDownloadableRemoteOnly) return false;
    if (entry.remoteLiveTitle != null &&
        widget.backend is HibikiClientSyncBackend) {
      final HibikiClientSyncBackend backend =
          widget.backend as HibikiClientSyncBackend;
      final Directory dir = _resolveTempDir();
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final File tmp = File(
        p.join(
          dir.path,
          'hibiki-compare-${DateTime.now().microsecondsSinceEpoch}.epub',
        ),
      );
      try {
        await backend.getRemoteBook(entry.remoteLiveTitle!, tmp);
        final String localBookKey = await EpubImporter.importFromPath(
          db: widget.db,
          filePath: tmp.path,
          fileName: '${entry.title}.epub',
        );
        // 750a：EPUB 导入成功后，若该远端书带有声书则一并补下音频包（与书架
        // 互联下载同接线）。bookKeyOverride 绑定到本地刚导入 EPUB 的 bookKey。
        await _downloadLiveAudiobookFor(backend, entry, localBookKey);
        return true;
      } finally {
        try {
          if (tmp.existsSync()) tmp.deleteSync();
        } catch (_) {
          // best-effort temp cleanup
        }
      }
    }
    final String? folderId = entry.remoteFolderId;
    if (folderId == null) return false;
    return importRemoteBookFolder(
      db: widget.db,
      backend: widget.backend,
      folderId: folderId,
      tempDir: _resolveTempDir(),
      // 云后端下载远端书时一并补下其有声书包（修复云有声书「只上传拿不回」缺口）。
      audioDatabaseRoot: widget.audioDatabaseRoot,
    );
  }

  Future<void> _downloadRemoteOnlyFromRow(SyncCompareEntry entry) async {
    if (_applying) return;
    setState(() {
      _applying = true;
      _progress = null;
      _progressLabel = entry.title;
    });
    try {
      bool imported = false;
      await runExclusiveWithSync(() async {
        imported = await _downloadRemoteOnlyBook(entry);
      });
      if (!mounted) return;
      setState(() {
        _applying = false;
        _progress = null;
        _progressLabel = null;
        if (imported) {
          _entries?.remove(entry);
          _choices.remove(entry.title);
        }
      });
    } on DuplicateImportCancelledException {
      if (mounted) {
        setState(() {
          _applying = false;
          _progress = null;
          _progressLabel = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _applying = false;
          _progress = null;
          _progressLabel = null;
          _error = friendlySyncError(e);
        });
      }
    }
  }

  /// 正在传输中的资产行（[_assetTag]），用于禁用该行按钮而不冻结整个对话框。
  final Set<String> _assetBusy = <String>{};

  static String _assetTag(SyncAssetEntry e) => '${e.kind.name}:${e.identity}';

  /// 传输单条资产：本端独有 → 上传；远端独有 → 下载。
  ///
  /// **复用编排器**（[SyncOrchestrator.assetScope] 收窄到这一条），而不是在对话框里
  /// 另写一份上传/下载。清单读-合并-回写、同尺寸幂等判据、upload-only 与墓碑语义都在
  /// 编排器里；再写一份必然与它漂开，而漂开的那份会悄悄传错或反复重传大文件。
  /// 云/互联走的也是编排器内部同一套分流，故「各个后端都支持」是同一条代码路径保证的。
  Future<void> _transferAsset(SyncAssetEntry e) async {
    final String tag = _assetTag(e);
    if (_assetBusy.contains(tag) || _applying) return;

    final Directory? audioRoot = widget.audioDatabaseRoot;
    final Directory? dictRoot = widget.dictionaryResourceRoot;
    // 缺依赖就如实说做不了，不假装成功也不静默 no-op。
    final String? missing = switch (e.kind) {
      SyncAssetKind.dictionary when dictRoot == null =>
        t.sync_compare_unavailable,
      SyncAssetKind.audiobook when audioRoot == null =>
        t.sync_compare_unavailable,
      SyncAssetKind.localAudioDb
          when !e.hasLocal && widget.onLocalAudioImported == null =>
        t.sync_compare_unavailable,
      _ => null,
    };
    if (missing != null) {
      showSyncMessage(context, missing);
      return;
    }

    setState(() => _assetBusy.add(tag));
    try {
      final SyncRunReport report = await runExclusiveWithSync(() async {
        if (e.kind == SyncAssetKind.audiobook) {
          return _transferAudiobook(e);
        }
        if (e.kind == SyncAssetKind.video && !e.hasLocal) {
          return _downloadVideo(e);
        }
        final SyncOrchestrator orchestrator = SyncOrchestrator(
          db: widget.db,
          backend: widget.backend,
          dictionaryResourceRoot: dictRoot ?? _resolveTempDir(),
          audioDatabaseRoot: audioRoot ?? _resolveTempDir(),
          tempDir: _resolveTempDir(),
          deviceId: await SyncRepository(widget.db).getOrCreateDeviceId(),
          // 这是用户对**这一条**的显式动作：四个开关全开，只靠 assetScope 收窄范围。
          // 沿用「本轮同步开关」会让点了上传却什么都没发生（开关默认关）。
          syncStats: false,
          syncAudioBookPosition: false,
          syncContent: true,
          syncAudioBookFiles: true,
          syncVideoFiles: true,
          syncDictionary: true,
          syncLocalAudio: true,
          localAudioEntries: widget.localAudioEntries,
          onLocalAudioImported: widget.onLocalAudioImported,
          assetScope: <SyncAssetKind, Set<String>>{
            e.kind: <String>{e.identity},
          },
        );
        return orchestrator.runAssetDimension(e.kind);
      });

      if (!mounted) return;
      // 三种结局分清楚：报错 / 真的传了 / 一条都没传（该通道对这条没有传输路径，
      // 例如云后端视频是 upload-only，远端独有的视频它拉不回来）。第三种绝不能当
      // 成功——行不能标成「两端都有」，提示也得如实说传不了。
      final bool moved = report.assetsTransferred > 0;
      setState(() {
        _assetBusy.remove(tag);
      });
      if (report.errors.isNotEmpty) {
        showSyncMessage(context, t.sync_error(message: report.errors.first));
      } else if (moved) {
        // 后端上传后返回的真实 locator 可能是 provider asset id，绝不能拿 identity
        // 伪造。重新列举让行状态、尺寸与后续删除都使用后端真值。
        await _load();
        if (!mounted) return;
        showSyncMessage(context, t.sync_compare_transferred(name: e.name));
      } else {
        showSyncMessage(context, t.sync_compare_transfer_unsupported);
      }
    } catch (err) {
      if (!mounted) return;
      setState(() => _assetBusy.remove(tag));
      showSyncMessage(context, friendlySyncError(err));
    }
  }

  Future<SyncRunReport> _transferAudiobook(SyncAssetEntry entry) async {
    final SyncRunReport report = SyncRunReport();
    File? tmp;
    try {
      tmp = File(p.join(
        _resolveTempDir().path,
        'hibiki_compare_${DateTime.now().microsecondsSinceEpoch}.hibikiaudio',
      ));
      await tmp.parent.create(recursive: true);
      final SyncAssetPackageService packages =
          SyncAssetPackageService(db: widget.db);

      if (entry.hasLocal) {
        SrtBookRow? srt = await widget.db.getSrtBookByBookKey(entry.identity);
        srt ??= await widget.db.getSrtBookByUid(entry.identity);
        if (srt == null) {
          throw StateError('local audiobook not found: ${entry.identity}');
        }
        await packages.exportAudioDatabasePackage(
          srtBookUid: srt.uid,
          bookKey: srt.bookKey.isEmpty ? null : srt.bookKey,
          outputFile: tmp,
        );
        if (widget.backend case final HibikiClientSyncBackend live) {
          await live.putRemoteAudiobook(entry.identity, tmp);
        } else {
          final String root = await widget.backend.findOrCreateRootFolder();
          final String folder = await widget.backend.ensureBookFolder(
            bookTitle: entry.name,
            rootFolderId: root,
          );
          await widget.backend.putAsset(folder, kSyncAudiobookAssetName, tmp);
        }
        report.audiobooksExported++;
      } else {
        if (widget.backend case final HibikiClientSyncBackend live) {
          await live.getRemoteAudiobook(entry.identity, tmp);
        } else {
          await widget.backend.getAsset(entry.remoteId!, tmp);
        }
        final EpubBookRow? localBook =
            await widget.db.getEpubBook(entry.identity);
        await packages.importAudioDatabasePackage(
          packageFile: tmp,
          audioDatabaseRoot: widget.audioDatabaseRoot!,
          bookKeyOverride: localBook == null ? null : entry.identity,
        );
        report.audiobooksImported++;
      }
    } catch (e) {
      report.errors.add('audiobook "${entry.name}": $e');
    } finally {
      try {
        if (tmp != null && tmp.existsSync()) tmp.deleteSync();
      } catch (_) {
        // best-effort temp cleanup
      }
    }
    return report;
  }

  Future<SyncRunReport> _downloadVideo(SyncAssetEntry entry) async {
    final SyncRunReport report = SyncRunReport();
    File? destination;
    File? subtitleDestination;
    File? coverDestination;
    try {
      final Directory dir = await AppPaths.remoteVideosDirectory();
      await dir.create(recursive: true);
      final String safe =
          entry.identity.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      String extension = '.mp4';
      Map<String, int> tagsAddedAt = const <String, int>{};
      Map<String, int> tagTombstones = const <String, int>{};
      String? subtitleSource;
      String? subtitleFormat;
      List<AudioCue> subtitleCues = const <AudioCue>[];

      if (widget.backend case final HibikiClientSyncBackend live) {
        final RemoteVideoInfo remote =
            (await live.listRemoteVideos()).firstWhere(
          (RemoteVideoInfo item) => item.id == entry.identity,
        );
        tagsAddedAt = remote.tagsAddedAt;
        tagTombstones = remote.tagTombstones;
        destination = File(p.join(dir.path, '$safe$extension'));
        await live.downloadRemoteVideo(entry.identity, destination);
        if (remote.hasSubtitle) {
          final String rawExt =
              p.extension(remote.subtitleFileName ?? '').toLowerCase();
          final String ext =
              <String>{'.ass', '.ssa', '.vtt', '.srt'}.contains(rawExt)
                  ? rawExt.substring(1)
                  : 'srt';
          final Directory subtitleDir =
              await AppPaths.videoSubtitlesDirectory();
          await subtitleDir.create(recursive: true);
          subtitleDestination = File(p.join(subtitleDir.path, '$safe.$ext'));
          await live.getRemoteVideoSubtitle(
              entry.identity, subtitleDestination);
          subtitleSource = subtitleDestination.path;
          subtitleFormat = ext;
          subtitleCues = parseSubtitleCues(
            content: await readTextWithEncoding(subtitleDestination),
            format: ext,
            bookUid: entry.identity,
          );
        }
      } else {
        final CloudRemoteVideoClient cloud =
            CloudRemoteVideoClient(backend: widget.backend);
        final RemoteVideoManifestEntry remote =
            (await cloud.listRemoteVideos()).firstWhere(
          (RemoteVideoManifestEntry item) => item.uid == entry.identity,
        );
        final String remoteExt = p.extension(remote.videoAsset);
        if (remoteExt.isNotEmpty) extension = remoteExt;
        tagsAddedAt = remote.tagsAddedAt;
        tagTombstones = remote.tagTombstones;
        destination = File(p.join(dir.path, '$safe$extension'));
        await cloud.getRemoteVideo(entry.identity, destination);
        coverDestination = File(p.join(dir.path, '$safe.cover.jpg'));
        if (!await cloud.getRemoteVideoCover(
          entry.identity,
          coverDestination,
        )) {
          coverDestination = null;
        }
      }

      await widget.db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value(entry.identity),
        title: Value(entry.name),
        videoPath: Value(destination.path),
        coverPath: Value<String?>(coverDestination?.path),
        subtitleSource: Value<String?>(subtitleSource),
        subtitleFormat: Value<String?>(subtitleFormat),
        embeddedSubtitleTrack: subtitleSource == null
            ? const Value<int?>(0)
            : const Value<int?>(null),
        importedAt: Value(DateTime.now()),
      ));
      if (subtitleCues.isNotEmpty) {
        await widget.db.replaceCuesForBook(
          entry.identity,
          subtitleCues.map(AudioCue.toCompanion).toList(),
        );
      }
      if (tagsAddedAt.isNotEmpty || tagTombstones.isNotEmpty) {
        await widget.db.mergeRemoteVideoTags(
          entry.identity,
          remoteAddedAt: tagsAddedAt,
          remoteTombstones: tagTombstones,
        );
      }
      report.videosImported++;
    } catch (e) {
      report.errors.add('video "${entry.name}": $e');
      try {
        if (destination != null && destination.existsSync()) {
          destination.deleteSync();
        }
        if (subtitleDestination != null && subtitleDestination.existsSync()) {
          subtitleDestination.deleteSync();
        }
        if (coverDestination != null && coverDestination.existsSync()) {
          coverDestination.deleteSync();
        }
      } catch (_) {
        // best-effort partial cleanup
      }
    }
    return report;
  }

  /// 删除前确认框：用户确认才返回 true。删除是不可逆的远端副作用。
  Future<bool> _confirmDelete(String name) async {
    final bool? ok = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => HibikiDialogFrame(
        maxWidth: 420,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(t.sync_compare_delete_confirm(name: name)),
            const SizedBox(height: 16),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: 8,
              children: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(t.dialog_cancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(t.dialog_delete),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    return ok ?? false;
  }

  /// 删除远端某项；成功后调用 [onSuccess] 做乐观本地移除并 setState。失败如实提示且不移除。
  Future<void> _deleteRemote({
    required String name,
    required String id,
    required bool isFolder,
    required VoidCallback onSuccess,
    Future<void> Function()? deleteAction,
  }) async {
    if (!await _confirmDelete(name)) return;
    try {
      if (deleteAction != null) {
        await deleteAction();
      } else {
        await widget.backend.deleteAsset(id, isFolder: isFolder);
      }
      if (isFolder) {
        // 删的是整本书文件夹：逐出书名→folderId 内存缓存里这个 folderId，再把
        // 逐出后的缓存重写回持久层。否则陈旧条目（书名仍映射到已删/已 trash 的
        // folderId）会被 ensureBookFolder 命中，上传打向 trashed 文件夹 → 复传石沉
        // （BUG-202）。DB 写不依赖 UI，放在 mounted 检查前以保证一定落盘。
        widget.backend.evictFolderId(id);
        await SyncRepository(widget.db)
            .setFolderCache(widget.backend.cachedFolderIds);
      }
      if (!mounted) return;
      setState(() {
        onSuccess();
        // 同一份远端资产可能同时被两处引用：书籍行的「远端有声书」子动作，和有声书
        // 区里它自己那一行。删掉的是**同一个** remoteId，两处必须一起失效——否则
        // 从书籍行删完，有声书那一行还理直气壮地显示「远端已有」，用户看到的是谎话。
        _forgetRemoteAsset(id);
      });
      showSyncMessage(context, t.sync_compare_deleted);
    } catch (e) {
      if (mounted) showSyncMessage(context, friendlySyncError(e));
    }
  }

  Future<void> _deleteRemoteAssetEntry(SyncAssetEntry entry) async {
    final SyncBackend backend = widget.backend;
    if (backend is HibikiClientSyncBackend) {
      switch (entry.kind) {
        case SyncAssetKind.dictionary:
          return backend.deleteRemoteDictionary(entry.identity);
        case SyncAssetKind.audiobook:
          return backend.deleteRemoteAudiobook(entry.identity);
        case SyncAssetKind.localAudioDb:
          return backend.deleteRemoteLocalAudio(entry.identity);
        case SyncAssetKind.video:
          return backend.deleteRemoteVideo(entry.identity);
      }
    }
    if (entry.kind == SyncAssetKind.video) {
      return CloudRemoteVideoClient(backend: backend)
          .deleteRemoteVideo(entry.identity);
    }
    return backend.deleteAsset(entry.remoteId!);
  }

  /// 远端 [assetId] 已确认删除：把资产列表里引用它的那一行同步失效。
  ///
  /// 本端也有 → 只掉远端那一半（行留着，可以再上传回去）；本端没有 → 整行移除
  /// （两端都没有的东西不是对比项）。调用方负责包在 setState 里。
  void _forgetRemoteAsset(String assetId) {
    final List<SyncAssetEntry>? assets = _assets;
    if (assets == null) return;
    for (int i = assets.length - 1; i >= 0; i--) {
      if (assets[i].remoteId != assetId) continue;
      if (assets[i].hasLocal) {
        assets[i] = assets[i].copyWith(clearRemote: true);
      } else {
        assets.removeAt(i);
      }
    }
  }

  /// 复制 entry 但清掉远端有声书 id（删完远端有声书后用，书籍行其它信息保留）。
  static SyncCompareEntry _copyWithoutAudio(SyncCompareEntry e) =>
      SyncCompareEntry(
        title: e.title,
        bookKey: e.bookKey,
        remoteFolderId: e.remoteFolderId,
        remoteLiveTitle: e.remoteLiveTitle,
        // Carry the content flag: dropping it would reset to the default true
        // and re-expose the phantom download on a content-less orphan after its
        // remote audiobook is deleted (BUG-049 regression).
        remoteHasContent: e.remoteHasContent,
        remoteAudioBookId: null,
        localProgress: e.localProgress,
        localUpdatedAt: e.localUpdatedAt,
        remoteProgress: e.remoteProgress,
        remoteUpdatedAt: e.remoteUpdatedAt,
        localStatsCount: e.localStatsCount,
        remoteStatsCount: e.remoteStatsCount,
        localAudioPosMs: e.localAudioPosMs,
        remoteAudioPosSec: e.remoteAudioPosSec,
        base: e.base,
      );

  int get _actionableCount {
    if (_entries == null) return 0;
    return _entriesInPlay.where(_isActionable).length;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = HibikiDesignTokens.of(context);
    final size = MediaQuery.sizeOf(context);

    Widget body;
    if (_error != null) {
      body = Center(
        child: Padding(
          padding: EdgeInsets.all(tokens.spacing.card),
          child:
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ),
      );
    } else if (_entries == null) {
      body = const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator.adaptive(),
        ),
      );
    } else if (widget.conflictsOnly
        ? _entriesInPlay.isEmpty
        : (_entries!.isEmpty &&
            (_assets?.isEmpty ?? true) &&
            _assetErrors.isEmpty)) {
      // 空态判定按「参与项」：conflictsOnly 下基于冲突项，无冲突即「无可解冲突」。
      body = Center(child: Text(t.sync_compare_empty));
    } else {
      final conflicts = _entriesInPlay.where((e) => e.hasConflict).toList();
      // conflictsOnly 模式只渲染冲突分组：隐藏自动可解的书与全部词典分组。
      final others = widget.conflictsOnly
          ? const <SyncCompareEntry>[]
          : _entries!.where((e) => !e.hasConflict).toList();
      final bool showAssets = !widget.conflictsOnly;
      final List<SyncAssetEntry> assets =
          showAssets ? (_assets ?? const <SyncAssetEntry>[]) : const [];

      body = ListView(
        children: [
          if (_assetErrors.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                _assetErrors.join('\n'),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          if (conflicts.isNotEmpty) ...[
            _sectionHeader(t.sync_compare_conflicts, theme, isConflict: true),
            for (final e in conflicts) _buildEntry(e, theme),
            if (others.isNotEmpty || assets.isNotEmpty)
              const Divider(height: 16),
          ],
          if (others.isNotEmpty) ...[
            if (conflicts.isNotEmpty)
              _sectionHeader(t.sync_compare_all_books, theme),
            for (final e in others) _buildEntry(e, theme),
          ],
          // 四类资产各成一节，恒定顺序（词典 → 有声书 → 音频数据库 → 视频），
          // 空的那一节整节不渲染。
          for (final SyncAssetKind kind in SyncAssetKind.values)
            ..._assetSection(kind, assets, theme),
        ],
      );
    }

    final applyCount = _actionableCount;
    final canApply = applyCount > 0 && !_applying && _entries != null;
    final maxWidth = (size.width * 0.7).clamp(400.0, 720.0);
    final maxBodyHeight = (size.height * 0.7).clamp(400.0, 640.0);

    return HibikiDialogFrame(
      maxWidth: maxWidth,
      scrollable: false,
      padding: EdgeInsets.all(tokens.spacing.card + 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  t.sync_compare_title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.listTitle.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (_entries != null && _entries!.isNotEmpty)
                HibikiOverflowMenu<SyncChoice>(
                  iconWidget: const Icon(Icons.checklist, size: 20),
                  tooltip: t.sync_compare_select_all,
                  onSelected: (choice) {
                    setState(() {
                      for (final e in _entries!) {
                        if (e.bookKey != null && e.needsManualChoice) {
                          _choices[e.title] = choice;
                        }
                      }
                    });
                  },
                  items: [
                    HibikiPopupMenuItem<SyncChoice>(
                      label: t.sync_compare_all_local,
                      icon: Icons.phone_android_outlined,
                      value: SyncChoice.useLocal,
                    ),
                    HibikiPopupMenuItem<SyncChoice>(
                      label: t.sync_compare_all_remote,
                      icon: Icons.cloud_outlined,
                      value: SyncChoice.useRemote,
                    ),
                    HibikiPopupMenuItem<SyncChoice>(
                      label: t.sync_compare_all_skip,
                      icon: Icons.block_outlined,
                      value: SyncChoice.skip,
                    ),
                  ],
                ),
            ],
          ),
          SizedBox(height: tokens.spacing.card),
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxBodyHeight),
              child: body,
            ),
          ),
          SizedBox(height: tokens.spacing.card),
          if (_applying) ...[
            LinearProgressIndicator(value: _progress),
            const SizedBox(height: 6),
            Text(
              _progressLabel ?? t.sync_compare_apply(count: _actionableCount),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            SizedBox(height: tokens.spacing.card),
          ],
          OverflowBar(
            alignment: MainAxisAlignment.end,
            spacing: tokens.spacing.gap,
            overflowSpacing: tokens.spacing.gap,
            children: [
              TextButton(
                onPressed: _applying ? null : () => Navigator.pop(context),
                child: Text(t.sync_compare_close),
              ),
              if (_entries != null && _entries!.isNotEmpty)
                FilledButton(
                  onPressed: canApply ? _applyChoices : null,
                  child: _applying
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(t.sync_compare_apply(count: applyCount)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String text, ThemeData theme,
      {bool isConflict = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Row(
        children: [
          if (isConflict) ...[
            Icon(Icons.warning_amber_rounded,
                size: 16, color: theme.colorScheme.error),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: theme.textTheme.labelLarge?.copyWith(
              color: isConflict
                  ? theme.colorScheme.error
                  : theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEntry(SyncCompareEntry entry, ThemeData theme) {
    final choice = _choices[entry.title] ?? SyncChoice.skip;
    final isConflict = entry.hasConflict;

    return HibikiCard(
      color: isConflict
          ? theme.colorScheme.errorContainer.withValues(alpha: 0.15)
          : Colors.transparent,
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      borderColor: isConflict ? theme.colorScheme.errorContainer : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _directionIcon(entry, theme),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  entry.title,
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isConflict)
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 4),
                  child: Icon(Icons.warning_amber_rounded,
                      size: 16, color: theme.colorScheme.error),
                ),
              if (entry.remoteFolderId != null ||
                  entry.remoteLiveTitle != null ||
                  entry.remoteAudioBookId != null)
                HibikiOverflowMenu<String>(
                  iconWidget: const Icon(Icons.delete_outline, size: 18),
                  tooltip: t.dialog_delete,
                  onSelected: (String sel) {
                    if (sel == 'book' &&
                        entry.remoteLiveTitle != null &&
                        widget.backend is HibikiClientSyncBackend) {
                      _deleteRemote(
                        name: entry.title,
                        id: entry.remoteLiveTitle!,
                        isFolder: false,
                        deleteAction: () =>
                            (widget.backend as HibikiClientSyncBackend)
                                .deleteRemoteBook(entry.remoteLiveTitle!),
                        onSuccess: () => _entries!.remove(entry),
                      );
                    } else if (sel == 'book' && entry.remoteFolderId != null) {
                      _deleteRemote(
                        name: entry.title,
                        id: entry.remoteFolderId!,
                        isFolder: true,
                        onSuccess: () => _entries!.remove(entry),
                      );
                    } else if (sel == 'audiobook' &&
                        entry.remoteAudioBookId != null) {
                      _deleteRemote(
                        name: entry.title,
                        id: entry.remoteAudioBookId!,
                        isFolder: false,
                        onSuccess: () {
                          // 删除成功那一刻才取索引，避免在 await 前预捕获索引
                          // 而期间列表变动导致的 stale 写入（与 book/dict 删除
                          // 一致的对象引用写法）。
                          final int idx = _entries!.indexOf(entry);
                          if (idx >= 0) {
                            _entries![idx] = _copyWithoutAudio(entry);
                          }
                        },
                      );
                    }
                  },
                  items: <PopupMenuEntry<String>>[
                    if (entry.remoteFolderId != null ||
                        (entry.remoteLiveTitle != null &&
                            widget.backend is HibikiClientSyncBackend))
                      HibikiPopupMenuItem<String>(
                        label: t.sync_compare_delete_book,
                        icon: Icons.menu_book_outlined,
                        value: 'book',
                      ),
                    if (entry.remoteAudioBookId != null)
                      HibikiPopupMenuItem<String>(
                        label: t.sync_compare_delete_audiobook,
                        icon: Icons.headphones_outlined,
                        value: 'audiobook',
                      ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 4),
          DefaultTextStyle(
            style: theme.textTheme.bodySmall!.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            child: Row(
              children: [
                Expanded(child: _dataColumn(entry, isLocal: true)),
                const SizedBox(height: 32, child: VerticalDivider(width: 16)),
                Expanded(child: _dataColumn(entry, isLocal: false)),
              ],
            ),
          ),
          if (entry.bookKey != null && entry.needsManualChoice) ...[
            const SizedBox(height: 6),
            _choiceRow(entry.title, choice, theme),
          ] else if (entry.isDownloadableRemoteOnly) ...[
            const SizedBox(height: 6),
            _downloadRow(entry, theme),
          ] else if (entry.bookKey == null &&
              (entry.remoteFolderId != null ||
                  entry.remoteLiveTitle != null)) ...[
            // Orphan remote folder: only sync metadata on the cloud, no book to
            // download. Show why (the delete menu above can clean it up) instead
            // of a download checkbox that could never succeed (BUG-049).
            const SizedBox(height: 6),
            Text(
              t.sync_compare_no_content,
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  Widget _downloadRow(SyncCompareEntry entry, ThemeData theme) {
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: TextButton.icon(
        onPressed: _applying ? null : () => _downloadRemoteOnlyFromRow(entry),
        icon: const Icon(Icons.cloud_download_outlined, size: 16),
        label: Text(t.sync_compare_download),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }

  /// 一类资产的整节（标题 + 行）；该类无条目时返回空列表（整节不渲染）。
  List<Widget> _assetSection(
    SyncAssetKind kind,
    List<SyncAssetEntry> all,
    ThemeData theme,
  ) {
    final List<SyncAssetEntry> rows =
        all.where((SyncAssetEntry e) => e.kind == kind).toList();
    if (rows.isEmpty) return const <Widget>[];
    return <Widget>[
      const Divider(height: 16),
      _sectionHeader(_assetSectionTitle(kind), theme),
      for (final SyncAssetEntry e in rows) _buildAssetEntry(e, theme),
    ];
  }

  static String _assetSectionTitle(SyncAssetKind kind) => switch (kind) {
        SyncAssetKind.dictionary => t.sync_compare_dictionaries,
        SyncAssetKind.audiobook => t.sync_compare_audiobooks,
        SyncAssetKind.localAudioDb => t.sync_compare_local_audio_dbs,
        SyncAssetKind.video => t.sync_compare_videos,
      };

  static IconData _assetIcon(SyncAssetKind kind) => switch (kind) {
        SyncAssetKind.dictionary => Icons.menu_book_outlined,
        SyncAssetKind.audiobook => Icons.headphones_outlined,
        SyncAssetKind.localAudioDb => Icons.graphic_eq_outlined,
        SyncAssetKind.video => Icons.video_file_outlined,
      };

  static String _assetDeleteLabel(SyncAssetKind kind) => switch (kind) {
        SyncAssetKind.dictionary => t.sync_compare_delete_dict,
        SyncAssetKind.audiobook => t.sync_compare_delete_audiobook,
        SyncAssetKind.localAudioDb => t.sync_compare_delete_local_audio_db,
        SyncAssetKind.video => t.sync_compare_delete_video,
      };

  /// 一条资产行：名字 + 两端存在性/大小 + 传输动作 + 删除远端。
  ///
  /// 存在性用与书籍行同一套「本端 / 远端」两列布局呈现，这样四类资产和书读起来是
  /// 同一张表，而不是各长各的样子。
  Widget _buildAssetEntry(SyncAssetEntry e, ThemeData theme) {
    final bool busy = _applying || _assetBusy.contains(_assetTag(e));
    return HibikiCard(
      color: Colors.transparent,
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                e.isSynced
                    ? Icons.check_circle_outline
                    : (e.hasLocal
                        ? Icons.cloud_upload_outlined
                        : Icons.cloud_download_outlined),
                size: 18,
                color: e.isSynced
                    ? theme.colorScheme.onSurfaceVariant
                    : (e.hasLocal
                        ? theme.colorScheme.tertiary
                        : theme.colorScheme.primary),
              ),
              const SizedBox(width: 6),
              Icon(_assetIcon(e.kind),
                  size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  e.name,
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (e.hasRemote)
                HibikiOverflowMenu<String>(
                  iconWidget: const Icon(Icons.delete_outline, size: 18),
                  tooltip: t.dialog_delete,
                  onSelected: (String _) => _deleteRemote(
                    name: e.name,
                    id: e.remoteId!,
                    isFolder: false,
                    deleteAction: () => _deleteRemoteAssetEntry(e),
                    // 行的失效交给 _deleteRemote 里统一的 _forgetRemoteAsset：
                    // 不管从哪个入口删的，同一个 remoteId 的引用一起失效。
                    onSuccess: () {},
                  ),
                  items: <PopupMenuEntry<String>>[
                    HibikiPopupMenuItem<String>(
                      label: _assetDeleteLabel(e.kind),
                      icon: Icons.delete_outline,
                      value: 'asset',
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 4),
          DefaultTextStyle(
            style: theme.textTheme.bodySmall!.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            child: Row(
              children: <Widget>[
                Expanded(child: _assetColumn(e, isLocal: true)),
                const SizedBox(height: 32, child: VerticalDivider(width: 16)),
                Expanded(child: _assetColumn(e, isLocal: false)),
              ],
            ),
          ),
          if (!e.isSynced) ...[
            const SizedBox(height: 6),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: busy ? null : () => _transferAsset(e),
                icon: Icon(
                  e.hasLocal
                      ? Icons.cloud_upload_outlined
                      : Icons.cloud_download_outlined,
                  size: 16,
                ),
                label: Text(e.hasLocal
                    ? t.sync_compare_upload
                    : t.sync_compare_download),
                style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _assetColumn(SyncAssetEntry e, {required bool isLocal}) {
    final bool present = isLocal ? e.hasLocal : e.hasRemote;
    final int? size = isLocal ? e.localSizeBytes : e.remoteSizeBytes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          isLocal ? t.sync_compare_local : t.sync_compare_remote,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        Text(present ? t.sync_compare_present : t.sync_compare_absent),
        if (present && size != null && size > 0) Text(_formatBytes(size)),
      ],
    );
  }

  static String _formatBytes(int bytes) {
    const List<String> units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
    double value = bytes.toDouble();
    int unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 100 || unit == 0 ? 0 : 1)}'
        '${units[unit]}';
  }

  Widget _directionIcon(SyncCompareEntry entry, ThemeData theme) {
    final cs = theme.colorScheme;
    final choice = _choices[entry.title] ?? SyncChoice.skip;
    if (choice == SyncChoice.useLocal) {
      return Icon(Icons.cloud_upload_outlined, size: 18, color: cs.tertiary);
    }
    if (choice == SyncChoice.useRemote) {
      return Icon(Icons.cloud_download_outlined, size: 18, color: cs.primary);
    }
    final icon = switch (entry.autoDirection) {
      SyncDirection.importFromTtu => Icons.cloud_download_outlined,
      SyncDirection.exportToTtu => Icons.cloud_upload_outlined,
      SyncDirection.synced => Icons.check_circle_outline,
    };
    final color = switch (entry.autoDirection) {
      SyncDirection.importFromTtu => cs.primary,
      SyncDirection.exportToTtu => cs.tertiary,
      SyncDirection.synced => cs.onSurfaceVariant,
    };
    return Icon(icon, size: 18, color: color);
  }

  Widget _choiceRow(String title, SyncChoice choice, ThemeData theme) {
    // Wrap as a single gamepad/keyboard focus stop (D-pad Left/Right cycles the
    // conflict resolution). A bare per-entry segmented button is an unregistered
    // native cluster; with only the header overflow menu registered, directional
    // nav would never land here and the user could not pick a choice or reach
    // Apply.
    return HibikiAdjustableSegmented<SyncChoice>(
      focusIdPrefix: 'sync-choice',
      values: const <SyncChoice>[
        SyncChoice.useLocal,
        SyncChoice.skip,
        SyncChoice.useRemote,
      ],
      selected: choice,
      onChanged: (SyncChoice value) {
        setState(() => _choices[title] = value);
      },
      child: adaptiveSegmentedButton<SyncChoice>(
        context: context,
        style: SegmentedButton.styleFrom(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: theme.textTheme.labelSmall,
        ),
        segments: [
          ButtonSegment(
            value: SyncChoice.useLocal,
            label: Text(t.sync_compare_use_local),
            tooltip: t.sync_compare_use_local,
          ),
          ButtonSegment(
            value: SyncChoice.skip,
            label: Text(t.sync_compare_skip),
            tooltip: t.sync_compare_skip,
          ),
          ButtonSegment(
            value: SyncChoice.useRemote,
            label: Text(t.sync_compare_use_remote),
            tooltip: t.sync_compare_use_remote,
          ),
        ],
        selected: {choice},
        onSelectionChanged: (Set<SyncChoice> sel) {
          setState(() => _choices[title] = sel.first);
        },
      ),
    );
  }

  Widget _dataColumn(SyncCompareEntry e, {required bool isLocal}) {
    final progress = isLocal ? e.localProgress : e.remoteProgress;
    final updatedAt = isLocal ? e.localUpdatedAt : e.remoteUpdatedAt;
    final statsCount = isLocal ? e.localStatsCount : e.remoteStatsCount;
    final hasAudio =
        isLocal ? e.localAudioPosMs != null : e.remoteAudioPosSec != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isLocal ? t.sync_compare_local : t.sync_compare_remote,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        if (progress != null)
          Text('${(progress * 100).toStringAsFixed(1)}%')
        else
          Text(t.sync_compare_no_data),
        if (updatedAt != null) Text(_formatTime(updatedAt)),
        if (statsCount != null && statsCount > 0)
          Text('${t.sync_statistics}: $statsCount ${t.sync_compare_days}'),
        if (hasAudio)
          Text(
            '${t.sync_audiobook}: ${isLocal ? _formatDuration(e.localAudioPosMs! ~/ 1000) : _formatDuration(e.remoteAudioPosSec!.round())}',
          ),
      ],
    );
  }

  static String _formatTime(int ms) =>
      HibikiTimeFormat.dateHourMinute(DateTime.fromMillisecondsSinceEpoch(ms));

  static String _pad(int n) => n.toString().padLeft(2, '0');

  static String _formatDuration(int totalSeconds) {
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    if (h > 0) return '${h}h${_pad(m)}m';
    return '${m}m${_pad(s)}s';
  }
}
