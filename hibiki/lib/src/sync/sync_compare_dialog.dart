import 'dart:developer' as developer;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/src/sync/google_drive_auth.dart';
import 'package:hibiki/src/sync/google_drive_handler.dart';
import 'package:hibiki/src/sync/position_converter.dart';
import 'package:hibiki/src/sync/sync_manager.dart';
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
  bool get hasConflict => hasLocal && hasRemote && localUpdatedAt != remoteUpdatedAt;
  bool get isSynced => hasLocal && hasRemote && localUpdatedAt == remoteUpdatedAt;

  SyncDirection get autoDirection {
    if (!hasLocal && !hasRemote) return SyncDirection.synced;
    if (!hasLocal) return SyncDirection.importFromTtu;
    if (!hasRemote) return SyncDirection.exportToTtu;
    if (localUpdatedAt! > remoteUpdatedAt!) return SyncDirection.exportToTtu;
    if (remoteUpdatedAt! > localUpdatedAt!) return SyncDirection.importFromTtu;
    return SyncDirection.synced;
  }
}

Future<List<SyncCompareEntry>> _fetchCompareData(HibikiDatabase db) async {
  final drive = GoogleDriveHandler.instance;
  final repo = SyncRepository(db);

  final rootId = await _ensureRoot(drive, repo);
  final remoteBooks = await drive.listBooks(rootId);
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

  final entries = <SyncCompareEntry>[];

  for (final title in allTitles) {
    final local = localByTitle[title];
    final sanitized = sanitizeTtuFilename(title);
    final remote = remoteByTitle[title] ?? remoteByTitle[sanitized];

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
        localAudioMs = await db.getPrefTyped<int>('audiobook_pos_${local.id}', 0);
        if (localAudioMs == 0) localAudioMs = null;
      } catch (e) {
        developer.log(
          'Failed to parse local data for "$title"',
          error: e,
          name: 'SyncCompare',
        );
      }
    }

    double? remoteProg;
    int? remoteUpdatedAt;
    int? remoteStatsCount;
    double? remoteAudioSec;

    if (remote != null) {
      try {
        final syncFiles = await drive.listSyncFiles(remote.id);
        if (syncFiles.progress != null) {
          final progress = await drive.getProgressFile(syncFiles.progress!.id);
          remoteProg = progress.progress;
          remoteUpdatedAt = progress.lastBookmarkModified;
        }
        if (syncFiles.statistics != null) {
          final stats = await drive.getStatsFile(syncFiles.statistics!.id);
          remoteStatsCount = stats.length;
        }
        if (syncFiles.audioBook != null) {
          final audio = await drive.getAudioBookFile(syncFiles.audioBook!.id);
          remoteAudioSec = audio.playbackPositionSec;
        }
      } catch (e) {
        developer.log(
          'Failed to fetch remote data for "$title"',
          error: e,
          name: 'SyncCompare',
        );
      }
    }

    entries.add(SyncCompareEntry(
      title: title,
      bookId: local?.id,
      localProgress: localProg,
      localUpdatedAt: localUpdatedAt,
      remoteProgress: remoteProg,
      remoteUpdatedAt: remoteUpdatedAt,
      localStatsCount: localStatsCount,
      remoteStatsCount: remoteStatsCount,
      localAudioPosMs: localAudioMs,
      remoteAudioPosSec: remoteAudioSec,
    ));
  }

  final rootIdNow = drive.cachedRootFolderId;
  if (rootIdNow != null) await repo.setRootFolderId(rootIdNow);
  final cache = drive.cachedFolderIds;
  if (cache.isNotEmpty) await repo.setFolderCache(cache);

  return entries;
}

Future<String> _ensureRoot(
  GoogleDriveHandler drive,
  SyncRepository repo,
) async {
  if (drive.cachedRootFolderId != null) return drive.cachedRootFolderId!;
  final savedRoot = await repo.getRootFolderId();
  final savedCache = await repo.getFolderCache();
  drive.restoreCache(rootFolderId: savedRoot, titleToFolderId: savedCache);
  return drive.findOrCreateRootFolder();
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
  final auth = GoogleDriveAuth.instance;
  if (!await auth.isAuthenticated) {
    if (!context.mounted) return;
    _showMessage(context, t.sync_not_signed_in);
    return;
  }

  if (!context.mounted) return;

  final applied = await showDialog<int>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _SyncCompareDialog(db: db),
  );
  if (applied != null && applied > 0 && context.mounted) {
    _showMessage(context, t.sync_compare_applied(count: applied));
  }
}

void _showMessage(BuildContext context, String msg) {
  if (isCupertinoPlatform(context)) {
    showCupertinoDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        content: Text(msg),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.dialog_done),
          ),
        ],
      ),
    );
    return;
  }
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

class _SyncCompareDialog extends StatefulWidget {
  const _SyncCompareDialog({required this.db});
  final HibikiDatabase db;

  @override
  State<_SyncCompareDialog> createState() => _SyncCompareDialogState();
}

class _SyncCompareDialogState extends State<_SyncCompareDialog> {
  List<SyncCompareEntry>? _entries;
  Map<String, SyncChoice> _choices = {};
  String? _error;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final entries = await _fetchCompareData(widget.db);
      final choices = <String, SyncChoice>{};
      for (final e in entries) {
        if (e.isSynced) {
          choices[e.title] = SyncChoice.skip;
        } else if (e.hasConflict) {
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
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _applyChoices() async {
    final entries = _entries;
    if (entries == null) return;

    setState(() => _applying = true);
    try {
      final manager = SyncManager(db: widget.db);
      final repo = SyncRepository(widget.db);
      final syncStats = await repo.isSyncStatsEnabled();
      final syncAudioBook = await repo.isSyncAudioBookEnabled();
      final syncModeStr = await repo.getSyncMode();
      final statsSyncMode = syncModeStr == 'replace'
          ? StatisticsSyncMode.replace
          : StatisticsSyncMode.merge;

      int applied = 0;
      final errors = <String>[];
      for (final entry in entries) {
        final choice = _choices[entry.title];
        if (choice == null || choice == SyncChoice.skip) continue;
        if (entry.bookId == null) continue;

        final book = await widget.db.getEpubBook(entry.bookId!);
        if (book == null) continue;

        final direction = choice == SyncChoice.useLocal
            ? SyncDirection.exportToTtu
            : SyncDirection.importFromTtu;

        try {
          await manager.syncBook(
            book: book,
            direction: direction,
            syncStats: syncStats,
            statsSyncMode: statsSyncMode,
            syncAudioBook: syncAudioBook,
          );
          applied++;
        } catch (e) {
          errors.add(entry.title);
          developer.log(
            'Failed to sync "${entry.title}"',
            error: e,
            name: 'SyncCompare',
          );
        }
      }

      if (mounted) {
        Navigator.pop(context, applied);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _applying = false;
          _error = e.toString();
        });
      }
    }
  }

  int get _actionableCount {
    if (_entries == null) return 0;
    return _entries!.where((e) {
      final c = _choices[e.title];
      return c != null && c != SyncChoice.skip;
    }).length;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget body;
    if (_error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
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

    return AlertDialog(
      title: Row(
        children: [
          Expanded(child: Text(t.sync_compare_title)),
          if (_entries != null && _entries!.isNotEmpty)
            PopupMenuButton<SyncChoice>(
              icon: const Icon(Icons.checklist, size: 20),
              tooltip: t.sync_compare_select_all,
              onSelected: (choice) {
                setState(() {
                  for (final e in _entries!) {
                    if (!e.isSynced && e.bookId != null) {
                      _choices[e.title] = choice;
                    }
                  }
                });
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: SyncChoice.useLocal,
                  child: Text(t.sync_compare_all_local),
                ),
                PopupMenuItem(
                  value: SyncChoice.useRemote,
                  child: Text(t.sync_compare_all_remote),
                ),
                PopupMenuItem(
                  value: SyncChoice.skip,
                  child: Text(t.sync_compare_all_skip),
                ),
              ],
            ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 480, maxWidth: 500),
        child: body,
      ),
      actions: [
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
    );
  }

  Widget _sectionHeader(String text, ThemeData theme, {bool isConflict = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Row(
        children: [
          if (isConflict) ...[
            Icon(Icons.warning_amber_rounded, size: 16, color: theme.colorScheme.error),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: theme.textTheme.labelLarge?.copyWith(
              color: isConflict ? theme.colorScheme.error : theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEntry(SyncCompareEntry entry, ThemeData theme) {
    final choice = _choices[entry.title] ?? SyncChoice.skip;
    final isConflict = entry.hasConflict;

    return Container(
      decoration: isConflict
          ? BoxDecoration(
              color: theme.colorScheme.errorContainer.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            )
          : null,
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
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
          if (!entry.isSynced && entry.bookId != null) ...[
            const SizedBox(height: 6),
            _choiceRow(entry.title, choice, theme),
          ],
        ],
      ),
    );
  }

  Widget _directionIcon(SyncCompareEntry entry, ThemeData theme) {
    final choice = _choices[entry.title] ?? SyncChoice.skip;
    if (choice == SyncChoice.useLocal) {
      return const Icon(Icons.cloud_upload_outlined, size: 18, color: Colors.orange);
    }
    if (choice == SyncChoice.useRemote) {
      return const Icon(Icons.cloud_download_outlined, size: 18, color: Colors.blue);
    }
    final icon = switch (entry.autoDirection) {
      SyncDirection.importFromTtu => Icons.cloud_download_outlined,
      SyncDirection.exportToTtu => Icons.cloud_upload_outlined,
      SyncDirection.synced => Icons.check_circle_outline,
    };
    final color = switch (entry.autoDirection) {
      SyncDirection.importFromTtu => Colors.blue,
      SyncDirection.exportToTtu => Colors.orange,
      SyncDirection.synced => Colors.green,
    };
    return Icon(icon, size: 18, color: color);
  }

  Widget _choiceRow(String title, SyncChoice choice, ThemeData theme) {
    return SegmentedButton<SyncChoice>(
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: theme.textTheme.labelSmall,
      ),
      segments: [
        ButtonSegment(
          value: SyncChoice.useLocal,
          label: Text(t.sync_compare_use_local),
          icon: const Icon(Icons.phone_android, size: 14),
        ),
        ButtonSegment(
          value: SyncChoice.skip,
          label: Text(t.sync_compare_skip),
          icon: const Icon(Icons.skip_next, size: 14),
        ),
        ButtonSegment(
          value: SyncChoice.useRemote,
          label: Text(t.sync_compare_use_remote),
          icon: const Icon(Icons.cloud_outlined, size: 14),
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
    final hasAudio = isLocal ? e.localAudioPosMs != null : e.remoteAudioPosSec != null;

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
