import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:hibiki/src/sync/position_converter.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

class SyncBookResult {
  const SyncBookResult({
    required this.direction,
    required this.title,
    this.characterCount,
    this.error,
  });

  final SyncResult direction;
  final String title;
  final int? characterCount;
  final String? error;
}

class SyncManager {
  SyncManager({
    required HibikiDatabase db,
    required SyncBackend backend,
    this.onContentProgress,
  })  : _db = db,
        _repo = SyncRepository(db),
        _backend = backend;

  final HibikiDatabase _db;
  final SyncRepository _repo;
  final SyncBackend _backend;

  /// Reports content-file (EPUB/audio) transfer progress as a fraction 0..1.
  /// Only fires when content sync is enabled and a file is being transferred.
  final void Function(double fraction)? onContentProgress;

  /// 同步单本书。返回同步结果。
  Future<SyncBookResult> syncBook({
    required EpubBookRow book,
    SyncDirection? direction,
    required bool syncStats,
    required StatisticsSyncMode statsSyncMode,
    required bool syncAudioBook,
    bool syncContent = false,
    bool importOnly = false,
  }) async {
    try {
      final result = await _syncBookOnce(
        book: book,
        direction: direction,
        syncStats: syncStats,
        statsSyncMode: statsSyncMode,
        syncAudioBook: syncAudioBook,
        syncContent: syncContent,
        importOnly: importOnly,
      );
      await _persistDriveCache();
      return result;
    } on SyncBackendError catch (e) {
      if (e.isRetryable) {
        _backend.clearCache();
        await _repo.clearFolderCache();
        try {
          final result = await _syncBookOnce(
            book: book,
            direction: direction,
            syncStats: syncStats,
            statsSyncMode: statsSyncMode,
            syncAudioBook: syncAudioBook,
            syncContent: syncContent,
            importOnly: importOnly,
          );
          await _persistDriveCache();
          return result;
        } on SyncBackendError catch (retryError) {
          return SyncBookResult(
            direction: SyncResult.skipped,
            title: book.title,
            error: retryError.message,
          );
        }
      }
      return SyncBookResult(
        direction: SyncResult.skipped,
        title: book.title,
        error: e.message,
      );
    } on SyncAuthError {
      rethrow;
    } catch (e) {
      return SyncBookResult(
        direction: SyncResult.skipped,
        title: book.title,
        error: e.toString(),
      );
    }
  }

  /// 同步所有已导入的 EPUB 书籍。
  Future<List<SyncBookResult>> syncAllBooks({
    required bool syncStats,
    required StatisticsSyncMode statsSyncMode,
    required bool syncAudioBook,
    bool syncContent = false,
    bool importOnly = false,
  }) async {
    final books = await _db.getAllEpubBooks();
    final results = <SyncBookResult>[];
    for (final book in books) {
      final result = await syncBook(
        book: book,
        syncStats: syncStats,
        statsSyncMode: statsSyncMode,
        syncAudioBook: syncAudioBook,
        syncContent: syncContent,
        importOnly: importOnly,
      );
      results.add(result);
    }
    await _repo.setLastSyncMs(DateTime.now().millisecondsSinceEpoch);
    await _persistDriveCache();
    return results;
  }

  Future<SyncBookResult> _syncBookOnce({
    required EpubBookRow book,
    SyncDirection? direction,
    required bool syncStats,
    required StatisticsSyncMode statsSyncMode,
    required bool syncAudioBook,
    bool syncContent = false,
    bool importOnly = false,
  }) async {
    await _restoreDriveCache();

    final rootId = await _backend.findOrCreateRootFolder();

    Uint8List? coverData;
    if (book.coverPath != null) {
      try {
        final file = File(book.coverPath!);
        if (file.existsSync()) coverData = file.readAsBytesSync();
      } catch (e) {
        debugPrint('[sync] cover image read failed: $e');
      }
    }

    final folderId = await _backend.ensureBookFolder(
      bookTitle: book.title,
      rootFolderId: rootId,
      coverData: coverData,
    );

    final syncFiles = await _backend.listSyncFiles(folderId);

    final localPosition = await _db.getReaderPosition(book.id);
    final chapters = parseChaptersJson(book.chaptersJson);

    final syncDir = direction ??
        _determineSyncDirection(
          localUpdatedAt: localPosition?.updatedAt,
          remoteProgressFile: syncFiles.progress,
        );

    if (syncDir == SyncDirection.synced) {
      return SyncBookResult(direction: SyncResult.synced, title: book.title);
    }
    if (importOnly && syncDir != SyncDirection.importFromTtu) {
      return SyncBookResult(direction: SyncResult.skipped, title: book.title);
    }

    final progressFileId = syncFiles.progress?.id;
    final statsFileId = syncStats ? syncFiles.statistics?.id : null;
    final audioBookFileId = syncAudioBook ? syncFiles.audioBook?.id : null;

    switch (syncDir) {
      case SyncDirection.importFromTtu:
        return _handleImport(
          book: book,
          folderId: folderId,
          chapters: chapters,
          progressFileId: progressFileId,
          statsFileId: statsFileId,
          audioBookFileId: audioBookFileId,
          statsSyncMode: statsSyncMode,
          syncStats: syncStats,
          syncAudioBook: syncAudioBook,
          syncContent: syncContent,
        );

      case SyncDirection.exportToTtu:
        if (localPosition == null && !syncContent) {
          return SyncBookResult(
              direction: SyncResult.skipped, title: book.title);
        }
        return _handleExport(
          book: book,
          folderId: folderId,
          chapters: chapters,
          localPosition: localPosition,
          progressFileId: progressFileId,
          statsFileId: statsFileId,
          audioBookFileId: audioBookFileId,
          syncStats: syncStats,
          syncAudioBook: syncAudioBook,
          statsSyncMode: statsSyncMode,
          syncContent: syncContent,
        );

      case SyncDirection.synced:
        return SyncBookResult(direction: SyncResult.synced, title: book.title);
    }
  }

  // ── Direction ─────────────────────────────────────────────────────

  SyncDirection _determineSyncDirection({
    required int? localUpdatedAt,
    required DriveFile? remoteProgressFile,
  }) {
    final int? remoteTimestamp = remoteProgressFile != null
        ? parseProgressTimestamp(remoteProgressFile.name)
        : null;

    if (localUpdatedAt == null && remoteTimestamp == null) {
      return SyncDirection.synced;
    }
    if (localUpdatedAt == null) return SyncDirection.importFromTtu;
    if (remoteTimestamp == null) return SyncDirection.exportToTtu;

    if (localUpdatedAt > remoteTimestamp) return SyncDirection.exportToTtu;
    if (remoteTimestamp > localUpdatedAt) return SyncDirection.importFromTtu;
    return SyncDirection.synced;
  }

  // ── Import ────────────────────────────────────────────────────────

  Future<SyncBookResult> _handleImport({
    required EpubBookRow book,
    required String folderId,
    required List<ChapterCharInfo> chapters,
    required String? progressFileId,
    required String? statsFileId,
    required String? audioBookFileId,
    required StatisticsSyncMode statsSyncMode,
    required bool syncStats,
    required bool syncAudioBook,
    bool syncContent = false,
  }) async {
    TtuProgress? remoteProgress;
    if (progressFileId != null) {
      remoteProgress = await _backend.getProgressFile(progressFileId);
    }
    if (remoteProgress == null) {
      return SyncBookResult(direction: SyncResult.skipped, title: book.title);
    }

    // Import progress — store exploredCharCount in ttuCharOffset for dirty-flag cache
    final pos = fromExploredCharCount(
      exploredCharCount: remoteProgress.exploredCharCount,
      chapters: chapters,
    );
    await _db.upsertReaderPosition(ReaderPositionsCompanion(
      ttuBookId: Value(book.id),
      sectionIndex: Value(pos.sectionIndex),
      normCharOffset: Value(pos.normCharOffset),
      ttuCharOffset: Value(remoteProgress.exploredCharCount),
      updatedAt: Value(remoteProgress.lastBookmarkModified),
    ));

    // Import statistics
    if (syncStats && statsFileId != null) {
      final remoteStats = await _backend.getStatsFile(statsFileId);
      final localStats = await _getLocalStatsForBook(book.title);
      final merged = _mergeStatistics(localStats, remoteStats, statsSyncMode);
      await _writeStatisticsToDb(merged);
    }

    // Import audiobook position
    if (syncAudioBook && audioBookFileId != null) {
      final remoteAudio = await _backend.getAudioBookFile(audioBookFileId);
      final posMs = (remoteAudio.playbackPositionSec * 1000).round();
      await _db.setPrefTyped('audiobook_pos_${book.id}', posMs);
    }

    // Import EPUB file if content sync is enabled and local file is missing
    if (syncContent) {
      await _importContentIfMissing(book: book, folderId: folderId);
    }

    return SyncBookResult(
      direction: SyncResult.imported,
      title: book.title,
      characterCount: remoteProgress.exploredCharCount,
    );
  }

  // ── Export ─────────────────────────────────────────────────────────

  Future<SyncBookResult> _handleExport({
    required EpubBookRow book,
    required String folderId,
    required List<ChapterCharInfo> chapters,
    required ReaderPositionRow? localPosition,
    required String? progressFileId,
    required String? statsFileId,
    required String? audioBookFileId,
    required bool syncStats,
    required bool syncAudioBook,
    required StatisticsSyncMode statsSyncMode,
    bool syncContent = false,
  }) async {
    int? exploredChars;

    // Export progress (only if we have a local reading position)
    if (localPosition != null) {
      // Dirty-flag cache: reuse stored exploredCharCount if local position is unchanged
      final cachedCharOffset = localPosition.ttuCharOffset;
      if (cachedCharOffset >= 0) {
        final cachedPos = fromExploredCharCount(
          exploredCharCount: cachedCharOffset,
          chapters: chapters,
        );
        final positionUnchanged = cachedPos.sectionIndex ==
                localPosition.sectionIndex &&
            (cachedPos.normCharOffset - localPosition.normCharOffset).abs() < 2;
        exploredChars = positionUnchanged
            ? cachedCharOffset
            : toExploredCharCount(
                sectionIndex: localPosition.sectionIndex,
                normCharOffset: localPosition.normCharOffset,
                chapters: chapters,
              );
      } else {
        exploredChars = toExploredCharCount(
          sectionIndex: localPosition.sectionIndex,
          normCharOffset: localPosition.normCharOffset,
          chapters: chapters,
        );
      }

      final total = totalCharacterCount(chapters);
      final progress = total > 0 ? exploredChars / total : 0.0;
      final timestampMs = localPosition.updatedAt;

      final ttuProgress = TtuProgress(
        dataId: 0,
        exploredCharCount: exploredChars,
        progress: progress,
        lastBookmarkModified: timestampMs,
      );

      await _backend.updateProgressFile(
        folderId: folderId,
        fileId: progressFileId,
        progress: ttuProgress,
      );

      // Export statistics
      if (syncStats) {
        final localStats = await _getLocalStatsForBook(book.title);
        List<TtuStatistics>? remoteStats;
        if (statsFileId != null) {
          remoteStats = await _backend.getStatsFile(statsFileId);
        }
        final merged =
            _mergeStatistics(remoteStats ?? [], localStats, statsSyncMode);
        if (merged.isNotEmpty) {
          await _backend.updateStatsFile(
            folderId: folderId,
            fileId: statsFileId,
            stats: merged,
          );
        }
      }

      // Export audiobook position
      if (syncAudioBook) {
        final posMs =
            await _db.getPrefTyped<int>('audiobook_pos_${book.id}', 0);
        if (posMs > 0) {
          final audioBook = TtuAudioBook(
            title: book.title,
            playbackPositionSec: posMs / 1000.0,
            lastAudioBookModified: DateTime.now().millisecondsSinceEpoch,
          );
          await _backend.updateAudioBookFile(
            folderId: folderId,
            fileId: audioBookFileId,
            audioBook: audioBook,
          );
        }
      }

      // Update local record: store exported exploredChars for dirty-flag cache
      await _db.upsertReaderPosition(ReaderPositionsCompanion(
        ttuBookId: Value(book.id),
        sectionIndex: Value(localPosition.sectionIndex),
        normCharOffset: Value(localPosition.normCharOffset),
        ttuCharOffset: Value(exploredChars),
        updatedAt: Value(timestampMs),
      ));
    }

    // Export EPUB file if content sync is enabled
    if (syncContent) {
      await _exportContentIfMissing(book: book, folderId: folderId);
    }

    return SyncBookResult(
      direction: SyncResult.exported,
      title: book.title,
      characterCount: exploredChars,
    );
  }

  // ── Content file sync ─────────────────────────────────────────────

  Future<void> _exportContentIfMissing({
    required EpubBookRow book,
    required String folderId,
  }) async {
    // Export EPUB
    final epubFile = File(book.epubPath);
    if (epubFile.existsSync()) {
      final fileName = '${sanitizeTtuFilename(book.title)}.epub';
      final existing = await _backend.findContentFile(folderId, fileName);
      if (existing == null) {
        await _backend.uploadContentFile(
          folderId: folderId,
          fileName: fileName,
          file: epubFile,
          onProgress: onContentProgress,
        );
      }
    }

    // Export audio files
    final audioPaths = await _resolveAudioPaths(book.id);
    for (final audioPath in audioPaths) {
      final audioFile = File(audioPath);
      if (!audioFile.existsSync()) continue;
      final audioName = p.basename(audioPath);
      final existing = await _backend.findContentFile(folderId, audioName);
      if (existing != null) continue;
      await _backend.uploadContentFile(
        folderId: folderId,
        fileName: audioName,
        file: audioFile,
        onProgress: onContentProgress,
      );
    }
  }

  Future<void> _importContentIfMissing({
    required EpubBookRow book,
    required String folderId,
  }) async {
    // Import EPUB
    if (!File(book.epubPath).existsSync()) {
      final fileName = '${sanitizeTtuFilename(book.title)}.epub';
      final remote = await _backend.findContentFile(folderId, fileName);
      if (remote != null) {
        final destination = File(book.epubPath);
        final parentDir = destination.parent;
        if (!parentDir.existsSync()) parentDir.createSync(recursive: true);
        await _backend.downloadContentFile(
          fileId: remote.id,
          destination: destination,
          onProgress: onContentProgress,
        );
      }
    }

    // Import audio files
    final audioPaths = await _resolveAudioPaths(book.id);
    for (final audioPath in audioPaths) {
      if (File(audioPath).existsSync()) continue;
      final audioName = p.basename(audioPath);
      final remote = await _backend.findContentFile(folderId, audioName);
      if (remote == null) continue;
      final destination = File(audioPath);
      final parentDir = destination.parent;
      if (!parentDir.existsSync()) parentDir.createSync(recursive: true);
      await _backend.downloadContentFile(
        fileId: remote.id,
        destination: destination,
        onProgress: onContentProgress,
      );
    }
  }

  static const _audioExtensions = {
    '.mp3',
    '.m4a',
    '.m4b',
    '.aac',
    '.ogg',
    '.opus',
    '.flac',
    '.wav',
    '.wma',
    '.ac3',
    '.eac3',
    '.mp4',
  };

  Future<List<String>> _resolveAudioPaths(int bookId) async {
    final bookUid = 'reader_ttu/hoshi://book/$bookId';
    final row = await _db.getAudiobookByBookUid(bookUid);
    if (row == null) return const [];

    if (row.audioPathsJson != null) {
      return (jsonDecode(row.audioPathsJson!) as List).cast<String>();
    }

    if (row.audioRoot != null) {
      final dir = Directory(row.audioRoot!);
      if (dir.existsSync()) {
        final paths = dir
            .listSync()
            .whereType<File>()
            .where((f) =>
                _audioExtensions.contains(p.extension(f.path).toLowerCase()))
            .map((f) => f.path)
            .toList()
          ..sort();
        return paths;
      }
    }

    return const [];
  }

  // ── Statistics merge ──────────────────────────────────────────────

  List<TtuStatistics> _mergeStatistics(
    List<TtuStatistics> localStats,
    List<TtuStatistics> externalStats,
    StatisticsSyncMode mode,
  ) =>
      mergeStatistics(localStats, externalStats, mode);

  // ── DB helpers ────────────────────────────────────────────────────

  Future<List<TtuStatistics>> _getLocalStatsForBook(String title) async {
    final rows = await _db.getAllReadingStatistics();
    return rows
        .where((r) => r.title == title)
        .map((r) => TtuStatistics(
              title: r.title,
              dateKey: r.dateKey,
              charactersRead: r.charactersRead,
              readingTimeSec: r.readingTimeMs / 1000.0,
              minReadingSpeed: 0,
              altMinReadingSpeed: 0,
              lastReadingSpeed: 0,
              maxReadingSpeed: 0,
              lastStatisticModified: r.lastStatisticModified,
            ))
        .toList();
  }

  Future<void> _writeStatisticsToDb(List<TtuStatistics> stats) async {
    for (final stat in stats) {
      await _db.setReadingStatistic(ReadingStatisticsCompanion(
        title: Value(stat.title),
        dateKey: Value(stat.dateKey),
        charactersRead: Value(stat.charactersRead),
        readingTimeMs: Value((stat.readingTimeSec * 1000).round()),
        lastStatisticModified: Value(stat.lastStatisticModified),
      ));
    }
  }

  // ── Drive cache persistence ───────────────────────────────────────

  Future<void> _restoreDriveCache() async {
    if (_backend.cachedRootFolderId != null) return;
    final rootId = await _repo.getRootFolderId();
    final folderCache = await _repo.getFolderCache();
    _backend.restoreCache(rootFolderId: rootId, titleToFolderId: folderCache);
  }

  Future<void> _persistDriveCache() async {
    final rootId = _backend.cachedRootFolderId;
    if (rootId != null) await _repo.setRootFolderId(rootId);
    final cache = _backend.cachedFolderIds;
    if (cache.isNotEmpty) await _repo.setFolderCache(cache);
  }
}

List<TtuStatistics> mergeStatistics(
  List<TtuStatistics> localStats,
  List<TtuStatistics> externalStats,
  StatisticsSyncMode mode,
) {
  if (mode == StatisticsSyncMode.replace) return externalStats;

  final grouped = <String, TtuStatistics>{};
  for (final stat in localStats) {
    grouped[stat.dateKey] = stat;
  }
  for (final stat in externalStats) {
    final existing = grouped[stat.dateKey];
    if (existing == null) {
      grouped[stat.dateKey] = stat;
    } else {
      grouped[stat.dateKey] = TtuStatistics(
        title: stat.title,
        dateKey: stat.dateKey,
        charactersRead: max(existing.charactersRead, stat.charactersRead),
        readingTimeSec: max(existing.readingTimeSec, stat.readingTimeSec),
        minReadingSpeed:
            existing.minReadingSpeed > 0 && stat.minReadingSpeed > 0
                ? min(existing.minReadingSpeed, stat.minReadingSpeed)
                : max(existing.minReadingSpeed, stat.minReadingSpeed),
        altMinReadingSpeed:
            existing.altMinReadingSpeed > 0 && stat.altMinReadingSpeed > 0
                ? min(existing.altMinReadingSpeed, stat.altMinReadingSpeed)
                : max(existing.altMinReadingSpeed, stat.altMinReadingSpeed),
        lastReadingSpeed: max(existing.lastReadingSpeed, stat.lastReadingSpeed),
        maxReadingSpeed: max(existing.maxReadingSpeed, stat.maxReadingSpeed),
        lastStatisticModified:
            max(existing.lastStatisticModified, stat.lastStatisticModified),
      );
    }
  }
  return grouped.values.toList();
}
