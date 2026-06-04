import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:hibiki/src/sync/position_converter.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_error_messages.dart';
import 'package:hibiki/src/sync/sync_manager.dart';
import 'package:hibiki/src/sync/sync_message_dialog.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/sync_progress_resolver.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

enum SyncChoice { skip, useLocal, useRemote }

class SyncCompareEntry {
  SyncCompareEntry({
    required this.title,
    required this.bookId,
    this.remoteFolderId,
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
  final int? bookId;

  /// 远端书籍文件夹的原生定位符（删除整本远端书用）；本端独有书为 null。
  final String? remoteFolderId;

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

/// 一条词典对比项：按词典名对齐本端与远端的存在性。
class SyncDictEntry {
  SyncDictEntry({
    required this.name,
    required this.hasLocal,
    this.remoteAssetId,
  });

  final String name;
  final bool hasLocal;

  /// 远端词典资产（`<name>.hibikidict`）定位符；远端没有则 null。
  final String? remoteAssetId;

  bool get hasRemote => remoteAssetId != null;
}

Future<List<SyncCompareEntry>> _fetchCompareData(
  HibikiDatabase db,
  SyncBackend backend,
) async {
  final repo = SyncRepository(db);

  final rootId = await _ensureRoot(backend, repo);
  // Reserved asset namespaces (e.g. __dictionaries__) live alongside book
  // folders under the root; they are not books and must not appear as phantom
  // compare entries.
  final remoteBooks = (await backend.listBooks(rootId))
      .where((DriveFile f) => !isReservedSyncFolderName(f.name))
      .toList();
  backend.cacheBookFolderIds(remoteBooks);
  final localBooks = await db.getAllEpubBooks();

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

  final allStats = await db.getAllReadingStatistics();
  final statCountByTitle = <String, int>{};
  for (final r in allStats) {
    statCountByTitle[r.title] = (statCountByTitle[r.title] ?? 0) + 1;
  }

  // Fetch remote data in parallel batches to avoid Drive API rate limits
  final remoteDataMap = <String, _RemoteBookData>{};
  final remoteJobs = <MapEntry<String, String>>[];
  for (final title in allTitles) {
    final sanitized = sanitizeTtuFilename(title);
    final remote = remoteByTitle[title] ?? remoteByTitle[sanitized];
    if (remote != null && !remoteJobs.any((e) => e.key == title)) {
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

  for (final title in allTitles) {
    final local = localByTitle[title];

    double? localProg;
    int? localUpdatedAt;
    int? localStatsCount;
    int? localAudioMs;

    if (local != null) {
      try {
        final pos = await db.getReaderPosition(local.id);
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
        localAudioMs = await repo.getAudiobookPosition(local.id);
        if (localAudioMs == 0) localAudioMs = null;
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

    // 跨设备资产身份与 SyncManager 一致：sanitizeTtuFilename(title)。读共同祖先
    // 基线，让「时间戳不等」收紧为「真分叉」冲突判定。
    final int? base =
        await db.getSyncBaseline(sanitizeTtuFilename(title), 'progress');

    entries.add(SyncCompareEntry(
      title: title,
      bookId: local?.id,
      remoteFolderId: remote?.id,
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

  return entries;
}

Future<List<SyncDictEntry>> _fetchDictEntries(
  HibikiDatabase db,
  SyncBackend backend, {
  required bool includeLocalOnly,
}) async {
  final String ns = await backend.ensureNamespace(kSyncDictionaryNamespace);
  final List<AssetEntry> remote = await backend.listChildren(ns);
  const String suffix = '.hibikidict';

  final Map<String, String> remoteByName = <String, String>{};
  for (final AssetEntry e in remote) {
    if (e.isFolder || !e.name.endsWith(suffix)) continue;
    remoteByName[e.name.substring(0, e.name.length - suffix.length)] = e.id;
  }
  final Set<String> localNames = <String>{
    for (final DictionaryMetaRow d in await db.getAllDictionaryMetadata())
      d.name,
  };

  final Set<String> allNames = <String>{...localNames, ...remoteByName.keys};
  final List<SyncDictEntry> out = <SyncDictEntry>[
    for (final String n in allNames)
      SyncDictEntry(
        name: n,
        hasLocal: localNames.contains(n),
        remoteAssetId: remoteByName[n],
      ),
  ];
  // 门控：远端项始终保留（要删它）；纯本地项（无远端可删）只在词典同步选项
  // 开启时才显示，避免选项关闭时用无关本地词典刷屏。
  out.removeWhere((SyncDictEntry e) => !e.hasRemote && !includeLocalOnly);
  out.sort((SyncDictEntry a, SyncDictEntry b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}

class _RemoteBookData {
  const _RemoteBookData({
    this.progress,
    this.updatedAt,
    this.statsCount,
    this.audioPosSec,
    this.audioBookId,
  });

  final double? progress;
  final int? updatedAt;
  final int? statsCount;
  final double? audioPosSec;

  /// 远端有声书资产（audiobook.hibikiaudio）的原生定位符；无则 null。
  final String? audioBookId;
}

Future<_RemoteBookData> _fetchRemoteBookData(
  SyncBackend backend,
  String folderId,
) async {
  try {
    final syncFiles = await backend.listSyncFiles(folderId);

    double? progress;
    int? updatedAt;
    int? statsCount;
    double? audioPosSec;
    String? audioBookId;

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
      audioBookId = syncFiles.audioBook!.id;
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
}) async {
  final repo = SyncRepository(db);
  final backend = resolveSyncBackend(await repo.getBackendType());
  if (!await backend.isAuthenticated) {
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
    super.key,
  });
  final HibikiDatabase db;
  final SyncBackend backend;

  /// 只显示真分叉冲突项（隐藏自动可解的书与词典分组）。冲突解决弹窗用。
  final bool conflictsOnly;

  @override
  State<SyncCompareDialog> createState() => _SyncCompareDialogState();
}

class _SyncCompareDialogState extends State<SyncCompareDialog> {
  List<SyncCompareEntry>? _entries;
  List<SyncDictEntry>? _dicts;
  Map<String, SyncChoice> _choices = {};
  String? _error;
  bool _applying = false;
  double? _progress;
  String? _progressLabel;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final repo = SyncRepository(widget.db);
      final bool dictSyncOn = await repo.isSyncDictionaryEnabled();
      final results = await Future.wait(<Future<Object>>[
        _fetchCompareData(widget.db, widget.backend),
        _fetchDictEntries(
          widget.db,
          widget.backend,
          includeLocalOnly: dictSyncOn,
        ),
      ]);
      final entries = results[0] as List<SyncCompareEntry>;
      final dicts = results[1] as List<SyncDictEntry>;
      final choices = <String, SyncChoice>{};
      for (final e in entries) {
        if (e.bookId == null || e.isSynced) {
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
          _dicts = dicts;
          _choices = choices;
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

  Future<void> _applyChoices() async {
    if (_entries == null) return;
    final entries = _entriesInPlay;

    // Only the books the user chose to sync count toward progress.
    final actionable = entries.where((e) {
      final c = _choices[e.title];
      return c != null && c != SyncChoice.skip && e.bookId != null;
    }).toList();
    final total = actionable.length;

    setState(() {
      _applying = true;
      _progress = total == 0 ? null : 0.0;
      _progressLabel = null;
    });
    try {
      final repo = SyncRepository(widget.db);
      final syncStats = await repo.isSyncStatsEnabled();
      final syncAudioBook = await repo.isSyncAudioBookEnabled();
      final syncContent = await repo.isSyncContentEnabled();

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

        final book = await widget.db.getEpubBook(entry.bookId!);
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
    } catch (e) {
      if (mounted) {
        setState(() {
          _applying = false;
          _error = friendlySyncError(e);
        });
      }
    }
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
  }) async {
    if (!await _confirmDelete(name)) return;
    try {
      await widget.backend.deleteAsset(id, isFolder: isFolder);
      if (!mounted) return;
      setState(onSuccess);
      showSyncMessage(context, t.sync_compare_deleted);
    } catch (e) {
      if (mounted) showSyncMessage(context, friendlySyncError(e));
    }
  }

  /// 复制 entry 但清掉远端有声书 id（删完远端有声书后用，书籍行其它信息保留）。
  static SyncCompareEntry _copyWithoutAudio(SyncCompareEntry e) =>
      SyncCompareEntry(
        title: e.title,
        bookId: e.bookId,
        remoteFolderId: e.remoteFolderId,
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
    return _entriesInPlay.where((e) {
      final c = _choices[e.title];
      return c != null && c != SyncChoice.skip && e.bookId != null;
    }).length;
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
        : (_entries!.isEmpty && (_dicts?.isEmpty ?? true))) {
      // 空态判定按「参与项」：conflictsOnly 下基于冲突项，无冲突即「无可解冲突」。
      body = Center(child: Text(t.sync_compare_empty));
    } else {
      final conflicts = _entriesInPlay.where((e) => e.hasConflict).toList();
      // conflictsOnly 模式只渲染冲突分组：隐藏自动可解的书与全部词典分组。
      final others = widget.conflictsOnly
          ? const <SyncCompareEntry>[]
          : _entries!.where((e) => !e.hasConflict).toList();
      final bool showDicts = !widget.conflictsOnly;

      body = ListView(
        children: [
          if (conflicts.isNotEmpty) ...[
            _sectionHeader(t.sync_compare_conflicts, theme, isConflict: true),
            for (final e in conflicts) _buildEntry(e, theme),
            if (others.isNotEmpty ||
                (showDicts && (_dicts?.isNotEmpty ?? false)))
              const Divider(height: 16),
          ],
          if (others.isNotEmpty) ...[
            if (conflicts.isNotEmpty)
              _sectionHeader(t.sync_compare_all_books, theme),
            for (final e in others) _buildEntry(e, theme),
          ],
          if (showDicts && _dicts != null && _dicts!.isNotEmpty) ...[
            const Divider(height: 16),
            _sectionHeader(t.sync_compare_dictionaries, theme),
            for (final SyncDictEntry d in _dicts!) _buildDictEntry(d, theme),
          ],
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
                        if (e.bookId != null && e.needsManualChoice) {
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
                child: Text(t.dialog_done),
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
                  entry.remoteAudioBookId != null)
                HibikiOverflowMenu<String>(
                  iconWidget: const Icon(Icons.delete_outline, size: 18),
                  tooltip: t.dialog_delete,
                  onSelected: (String sel) {
                    if (sel == 'book' && entry.remoteFolderId != null) {
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
                    if (entry.remoteFolderId != null)
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
          if (entry.bookId != null && entry.needsManualChoice) ...[
            const SizedBox(height: 6),
            _choiceRow(entry.title, choice, theme),
          ],
        ],
      ),
    );
  }

  Widget _buildDictEntry(SyncDictEntry d, ThemeData theme) {
    return HibikiCard(
      color: Colors.transparent,
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      child: Row(
        children: <Widget>[
          Icon(Icons.menu_book_outlined,
              size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              d.name,
              style: theme.textTheme.titleSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            d.hasRemote ? t.sync_compare_remote : t.sync_compare_local,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          if (d.hasRemote)
            HibikiOverflowMenu<String>(
              iconWidget: const Icon(Icons.delete_outline, size: 18),
              tooltip: t.dialog_delete,
              onSelected: (String _) => _deleteRemote(
                name: d.name,
                id: d.remoteAssetId!,
                isFolder: false,
                onSuccess: () => _dicts!.remove(d),
              ),
              items: <PopupMenuEntry<String>>[
                HibikiPopupMenuItem<String>(
                  label: t.sync_compare_delete_dict,
                  icon: Icons.delete_outline,
                  value: 'dict',
                ),
              ],
            ),
        ],
      ),
    );
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

  static String _formatTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)} ${_pad(dt.hour)}:${_pad(dt.minute)}';
  }

  static String _pad(int n) => n.toString().padLeft(2, '0');

  static String _formatDuration(int totalSeconds) {
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    if (h > 0) return '${h}h${_pad(m)}m';
    return '${m}m${_pad(s)}s';
  }
}
