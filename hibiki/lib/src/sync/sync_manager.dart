import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:hibiki/src/sync/position_converter.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_progress_resolver.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

/// Re-package an extracted book directory back into a single `.epub` at
/// [outputPath]. Hibiki stores imported books EXTRACTED (the extract dir is a
/// valid EPUB layout: `mimetype` + `META-INF/` + OPF + content) and keeps no
/// standalone `.epub` on disk, so content sync must rebuild one to upload
/// (BUG-088). Entries are rooted at the zip top (`includeDirName: false`) so
/// `mimetype` / `META-INF` sit at the archive root and the result re-imports
/// cleanly via [EpubImporter] on the other device.
///
/// Returns true if an archive was written; false when [extractDir] is empty or
/// absent (nothing to package).
Future<bool> repackageExtractedEpub(
  String extractDir,
  String outputPath,
) async {
  if (extractDir.isEmpty) return false;
  final Directory dir = Directory(extractDir);
  if (!dir.existsSync()) return false;
  final ZipFileEncoder encoder = ZipFileEncoder();
  encoder.create(outputPath);
  try {
    encoder.addDirectory(dir, includeDirName: false);
  } finally {
    encoder.close();
  }
  return true;
}

class SyncBookResult {
  const SyncBookResult({
    required this.direction,
    required this.title,
    this.characterCount,
    this.error,
    this.conflictAssetKey,
    this.conflictDimension,
    this.conflictLocalVersion,
    this.conflictRemoteVersion,
  });

  final SyncResult direction;
  final String title;
  final int? characterCount;
  final String? error;

  // Populated only when `direction == SyncResult.conflict`. The local/remote
  // versions are the diverging progress timestamps; downstream UI uses them
  // (with assetKey+dimension) as a dedup fingerprint for the resolution prompt.
  final String? conflictAssetKey;
  final String? conflictDimension;
  final int? conflictLocalVersion;
  final int? conflictRemoteVersion;
}

/// 单本书一次同步的归类结果：成功应用 / 真失败 / 良性空操作。
///
/// [SyncResult.skipped] 既可能是「无可传输内容」的良性跳过（`error == null`，
/// 例如导出方向但本地无阅读位置且未开内容同步），也可能是 [SyncManager.syncBook]
/// 把真实异常吞进 [SyncBookResult.error] 后返回的失败。两者不能都当成「同步错误」，
/// 否则良性跳过会误报为失败（BUG-014）。
enum SyncApplyOutcome { applied, failed, noop }

/// 把 [SyncBookResult] 归类为 [SyncApplyOutcome]。先看 [SyncBookResult.error]
/// 区分真失败，再按 [SyncResult] 区分实际发生传输（imported/exported）与无操作
/// （synced/良性 skipped/conflict 跳过）。纯函数，便于单测覆盖分类边界。
SyncApplyOutcome classifySyncApply(SyncBookResult result) {
  if (result.error != null) return SyncApplyOutcome.failed;
  switch (result.direction) {
    case SyncResult.imported:
    case SyncResult.exported:
      return SyncApplyOutcome.applied;
    case SyncResult.synced:
    case SyncResult.skipped:
    case SyncResult.conflict:
      // 冲突被自动同步跳过、不写任何数据，属良性无操作；交由 compare 对话框裁决。
      return SyncApplyOutcome.noop;
  }
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
        // 仅丢内存态让重试重新解析；不清磁盘 folder 缓存。否则一次瞬时错误
        // （网络超时等）会逼着重试及之后每个会话对每本书全量重做文件夹查找，
        // 直到下次完全成功。陈旧 ID 会被后端拒绝(404/auth)后在错误路径自愈。
        // 后端切换/登出仍显式 clearFolderCache（那才是有意失效）。
        _backend.clearCache();
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
    void Function(int done, int total, String title)? onBookProgress,
  }) async {
    final books = await _db.getAllEpubBooks();
    final results = <SyncBookResult>[];
    for (int i = 0; i < books.length; i++) {
      final book = books[i];
      onBookProgress?.call(i, books.length, book.title);
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

    final localPosition = await _db.getReaderPosition(book.bookKey);
    final chapters = parseChaptersJson(book.chaptersJson);

    // HBK-AUDIT-047: compute the local progress fraction so a timestamp tie
    // can be broken by actual content instead of silently declaring 'synced'.
    final double? localProgress = localPosition != null
        ? _localProgressFraction(localPosition, chapters)
        : null;

    final int? remoteTimestamp = syncFiles.progress != null
        ? parseProgressTimestamp(syncFiles.progress!.name)
        : null;
    final String assetKey = sanitizeTtuFilename(book.title);

    final SyncDirection syncDir;
    if (direction != null) {
      // Manual (compare-dialog) path: caller owns the direction, so no
      // three-way conflict gate here. The baseline IS still written after the
      // transfer lands below, so a user-resolved conflict records its new
      // common ancestor and stops re-surfacing as a conflict.
      syncDir = direction;
    } else {
      // Auto path: gate on the common-ancestor baseline. A genuine fork
      // (both sides moved off base) must surface as a conflict instead of
      // silently last-write-wins clobbering one side.
      final int? base = await _db.getSyncBaseline(assetKey, 'progress');
      final ProgressResolution res = resolveProgressSync(
        local: localPosition?.updatedAt,
        remote: remoteTimestamp,
        base: base,
      );
      if (res.isConflict) {
        return SyncBookResult(
          direction: SyncResult.conflict,
          title: book.title,
          conflictAssetKey: assetKey,
          conflictDimension: 'progress',
          conflictLocalVersion: localPosition?.updatedAt,
          conflictRemoteVersion: remoteTimestamp,
        );
      }
      // Non-conflict: honour the resolver's direction. It agrees with the
      // legacy last-write-wins outcome for single-sided / unanimous cases;
      // when both timestamps are equal it returns `synced`, so fall back to
      // the content-aware tie-break for the genuine same-ms collision.
      syncDir = res.direction == SyncDirection.synced &&
              localPosition?.updatedAt != null &&
              remoteTimestamp != null
          ? _determineSyncDirection(
              localUpdatedAt: localPosition?.updatedAt,
              localProgress: localProgress,
              remoteProgressFile: syncFiles.progress,
            )
          : res.direction;
    }

    if (syncDir == SyncDirection.synced) {
      // Both sides already agree on this timestamp: record it as the new base
      // so a later single-sided edit is recognised instead of re-colliding.
      // Written on both auto and manual paths — once both sides agree, the
      // common ancestor is this timestamp regardless of who decided it.
      if (localPosition?.updatedAt != null) {
        await _db.setSyncBaseline(
            assetKey, 'progress', localPosition!.updatedAt);
      }
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
        final SyncBookResult result = await _handleImport(
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
        // Base = remote progress timestamp = the updatedAt import wrote locally
        // (_handleImport stores remoteProgress.lastBookmarkModified, which
        // equals the remote filename timestamp). Both sides now agree on it.
        // Written on both auto and manual (compare useRemote→import) paths so a
        // resolved conflict's new common ancestor is recorded and the divergence
        // stops reading as a conflict next time.
        if (result.direction == SyncResult.imported &&
            remoteTimestamp != null) {
          await _db.setSyncBaseline(assetKey, 'progress', remoteTimestamp);
        }
        return result;

      case SyncDirection.exportToTtu:
        if (localPosition == null && !syncContent) {
          return SyncBookResult(
              direction: SyncResult.skipped, title: book.title);
        }
        final SyncBookResult result = await _handleExport(
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
        // Base = the timestamp _handleExport wrote into the remote progress
        // file, which is localPosition.updatedAt (also written back locally).
        // Only persist when a position was actually exported. Written on both
        // auto and manual (compare useLocal→export) paths so a resolved
        // conflict's new common ancestor is recorded.
        if (result.direction == SyncResult.exported &&
            localPosition?.updatedAt != null) {
          await _db.setSyncBaseline(
              assetKey, 'progress', localPosition!.updatedAt);
        }
        return result;

      case SyncDirection.synced:
        return SyncBookResult(direction: SyncResult.synced, title: book.title);
    }
  }

  // ── Direction ─────────────────────────────────────────────────────

  SyncDirection _determineSyncDirection({
    required int? localUpdatedAt,
    required double? localProgress,
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

    // HBK-AUDIT-047: timestamps collide to the same millisecond. Wall-clock
    // ties are realistic (two devices saving within the same ms, clock-equal
    // restores), and the progress fraction is encoded in the remote filename,
    // so break the tie on actual content instead of silently skipping. Whoever
    // has read further wins — the larger reading position is the value worth
    // keeping. Only fall back to 'synced' when both sides genuinely agree (or
    // the remote fraction is unparseable / local content unknown).
    final double? remoteProgress =
        _parseRemoteProgressFraction(remoteProgressFile!.name);
    if (localProgress == null || remoteProgress == null) {
      return SyncDirection.synced;
    }
    const double epsilon = 1e-6;
    final double delta = localProgress - remoteProgress;
    if (delta.abs() <= epsilon) return SyncDirection.synced;
    return delta > 0 ? SyncDirection.exportToTtu : SyncDirection.importFromTtu;
  }

  /// HBK-AUDIT-047: local reading progress as a 0..1 fraction, mirroring the
  /// fraction embedded in the remote progress filename. Uses the dirty-flag
  /// cache (`ttuCharOffset`) when valid, otherwise converts the live position.
  double? _localProgressFraction(
    ReaderPositionRow localPosition,
    List<ChapterCharInfo> chapters,
  ) {
    final int total = totalCharacterCount(chapters);
    if (total <= 0) return null;
    final int cachedCharOffset = localPosition.ttuCharOffset;
    final int exploredChars = cachedCharOffset >= 0
        ? cachedCharOffset
        : toExploredCharCount(
            sectionIndex: localPosition.sectionIndex,
            normCharOffset: localPosition.normCharOffset,
            chapters: chapters,
          );
    return exploredChars / total;
  }

  /// HBK-AUDIT-047: progress filenames are `progress_1_6_{timestamp}_{fraction}.json`;
  /// extract the trailing fraction so a timestamp tie can compare content.
  double? _parseRemoteProgressFraction(String fileName) {
    if (!fileName.startsWith('progress_')) return null;
    final String base = fileName.endsWith('.json')
        ? fileName.substring(0, fileName.length - '.json'.length)
        : fileName;
    final List<String> parts = base.split('_');
    if (parts.length < 5) return null;
    return double.tryParse(parts[4]);
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
      bookKey: Value(book.bookKey),
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
      await _repo.setAudiobookPosition(book.bookKey, posMs);
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
        final posMs = await _repo.getAudiobookPosition(book.bookKey);
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
        bookKey: Value(book.bookKey),
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
    // Export EPUB. There is NO standalone .epub on disk — books are stored
    // extracted, and book.epubPath is only the original filename (it never
    // resolves to a real file, so the old `File(book.epubPath).existsSync()`
    // guard silently skipped every upload — BUG-088). Re-package the extracted
    // directory into a temp .epub and upload that.
    if (book.extractDir.isNotEmpty && Directory(book.extractDir).existsSync()) {
      final fileName = '${sanitizeTtuFilename(book.title)}.epub';
      final existing = await _backend.findContentFile(folderId, fileName);
      if (existing == null) {
        final Directory tmpDir =
            Directory.systemTemp.createTempSync('hibiki_epub_export');
        final File epubTmp = File(p.join(tmpDir.path, fileName));
        try {
          final bool built =
              await repackageExtractedEpub(book.extractDir, epubTmp.path);
          if (built) {
            await _backend.uploadContentFile(
              folderId: folderId,
              fileName: fileName,
              file: epubTmp,
              onProgress: onContentProgress,
            );
          }
        } finally {
          try {
            tmpDir.deleteSync(recursive: true);
          } catch (_) {/* best-effort temp cleanup */}
        }
      }
    }

    // Export audio files
    final audioPaths = await _resolveAudioPaths(book.bookKey);
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
    // Import EPUB: a locally-present book already has its content in its
    // extracted directory; there is no standalone .epub to (re)download. The
    // old code keyed off `File(book.epubPath).existsSync()` — always false for
    // the bare filename — and downloaded the epub to that bare path, polluting
    // the process CWD and never re-extracting (BUG-088). Remote-only books are
    // imported by importRemoteBookFolder, so here we only act when the local
    // content is genuinely gone; recovery/re-extract is out of scope, so skip
    // rather than write a stray file.
    final bool contentPresent =
        book.extractDir.isNotEmpty && Directory(book.extractDir).existsSync();
    if (!contentPresent) {
      debugPrint('[SyncManager] book "${book.title}" content missing locally '
          '(extractDir gone); skipping epub re-import (remote-book import owns '
          'recovery).');
    }

    // Import audio files
    final audioPaths = await _resolveAudioPaths(book.bookKey);
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

  Future<List<String>> _resolveAudioPaths(String bookKey) async {
    final row = await _db.getAudiobookByBookKey(bookKey);
    if (row == null) return const [];

    if (row.audioPathsJson != null) {
      // HBK-AUDIT-138: a malformed audioPathsJson row must not throw an
      // unguarded Format/CastError that aborts content sync for the book.
      // Parse defensively and fall through to the audioRoot scan on failure.
      try {
        final dynamic decoded = jsonDecode(row.audioPathsJson!);
        if (decoded is List) {
          return decoded.whereType<String>().toList();
        }
      } on FormatException catch (e) {
        debugPrint('[sync] audioPathsJson decode failed for book $bookKey: $e');
      }
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
