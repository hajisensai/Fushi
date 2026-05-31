import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:hibiki/src/sync/position_converter.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_error_messages.dart';
import 'package:hibiki/src/sync/sync_manager.dart';
import 'package:hibiki/src/sync/sync_message_dialog.dart';
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
    this.localProgress,
    this.localUpdatedAt,
    this.remoteProgress,
    this.remoteUpdatedAt,
    this.localStatsCount,
    this.remoteStatsCount,
    this.localAudioPosMs,
    this.remoteAudioPosSec,
  });

  final String title;
  final int? bookId;
  final double? localProgress;
  final int? localUpdatedAt;
  final double? remoteProgress;
  final int? remoteUpdatedAt;
  final int? localStatsCount;
  final int? remoteStatsCount;
  final int? localAudioPosMs;
  final double? remoteAudioPosSec;

  bool get hasLocal => localUpdatedAt != null;
  bool get hasRemote => remoteUpdatedAt != null;
  bool get hasConflict =>
      hasLocal && hasRemote && localUpdatedAt != remoteUpdatedAt;
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

Future<List<SyncCompareEntry>> _fetchCompareData(
  HibikiDatabase db,
  SyncBackend backend,
) async {
  final repo = SyncRepository(db);

  final rootId = await _ensureRoot(backend, repo);
  final remoteBooks = await backend.listBooks(rootId);
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

    entries.add(SyncCompareEntry(
      title: title,
      bookId: local?.id,
      localProgress: localProg,
      localUpdatedAt: localUpdatedAt,
      remoteProgress: remoteData?.progress,
      remoteUpdatedAt: remoteData?.updatedAt,
      localStatsCount: localStatsCount,
      remoteStatsCount: remoteData?.statsCount,
      localAudioPosMs: localAudioMs,
      remoteAudioPosSec: remoteData?.audioPosSec,
    ));
  }

  final rootIdNow = backend.cachedRootFolderId;
  if (rootIdNow != null) await repo.setRootFolderId(rootIdNow);
  final cache = backend.cachedFolderIds;
  if (cache.isNotEmpty) await repo.setFolderCache(cache);

  return entries;
}

class _RemoteBookData {
  const _RemoteBookData({
    this.progress,
    this.updatedAt,
    this.statsCount,
    this.audioPosSec,
  });

  final double? progress;
  final int? updatedAt;
  final int? statsCount;
  final double? audioPosSec;
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
  HibikiDatabase db,
) async {
  final repo = SyncRepository(db);
  final backend = resolveSyncBackend(await repo.getBackendType());
  if (!await backend.isAuthenticated) {
    if (!context.mounted) return;
    showSyncMessage(context, t.sync_not_signed_in);
    return;
  }

  if (!context.mounted) return;

  final applied = await showAppDialog<int>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _SyncCompareDialog(db: db, backend: backend),
  );
  if (applied != null && applied > 0 && context.mounted) {
    showSyncMessage(context, t.sync_compare_applied(count: applied));
  }
}

class _SyncCompareDialog extends StatefulWidget {
  const _SyncCompareDialog({required this.db, required this.backend});
  final HibikiDatabase db;
  final SyncBackend backend;

  @override
  State<_SyncCompareDialog> createState() => _SyncCompareDialogState();
}

class _SyncCompareDialogState extends State<_SyncCompareDialog> {
  List<SyncCompareEntry>? _entries;
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
      final entries = await _fetchCompareData(widget.db, widget.backend);
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
          _choices = choices;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = friendlySyncError(e));
    }
  }

  Future<void> _applyChoices() async {
    final entries = _entries;
    if (entries == null) return;

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
          if (result.direction != SyncResult.skipped) {
            applied++;
          } else {
            errors.add(entry.title);
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

  int get _actionableCount {
    if (_entries == null) return 0;
    return _entries!.where((e) {
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
    } else if (_entries!.isEmpty) {
      body = Center(child: Text(t.sync_compare_empty));
    } else {
      final conflicts = _entries!.where((e) => e.hasConflict).toList();
      final others = _entries!.where((e) => !e.hasConflict).toList();

      body = ListView(
        children: [
          if (conflicts.isNotEmpty) ...[
            _sectionHeader(t.sync_compare_conflicts, theme, isConflict: true),
            for (final e in conflicts) _buildEntry(e, theme),
            const Divider(height: 16),
          ],
          if (others.isNotEmpty) ...[
            if (conflicts.isNotEmpty)
              _sectionHeader(t.sync_compare_all_books, theme),
            for (final e in others) _buildEntry(e, theme),
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
    return adaptiveSegmentedButton<SyncChoice>(
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
