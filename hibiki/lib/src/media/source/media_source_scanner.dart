// TODO-817 M1b source-library scanner: scans one MediaSource (local folder root)
// into many books/videos, backfilling sourceId on insert, then writes the
// media-count / scan-time / scan-error back onto MediaSources.
//
// [planScanFromFileList] is a pure function (no IO): it takes a SourceFileEntry
// list and classifies into epub / video / subtitle, associating each video with
// its same-stem sidecar subtitle via the existing sidecar pure function.
// [MediaSourceScanner.scan] is the thin IO orchestration: list via
// SourceFileSystem (M1b wires only LocalSourceFileSystem) -> planScanFromFileList
// -> reuse existing importers (EpubImporter.importFromPath /
// VideoBookRepository.saveVideoBook) with sourceId -> updateMediaSourceScanResult.
//
// Zero-behaviour-change: only a new scan entry is added; existing manual import
// paths (dialogs) are untouched, sourceId defaults to null. Network transport is
// still a placeholder (NetworkSourceFileSystem throws UnimplementedError); M1b
// does not connect to any network and does not touch credentials.

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/src/epub/book_title_conflict.dart';
import 'package:hibiki/src/epub/epub_importer.dart';
import 'package:hibiki/src/media/audiobook/audiobook_alignment_service.dart';
import 'package:hibiki/src/media/import/sidecar_finder.dart';
import 'package:hibiki/src/media/source/source_file_system.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_filename_parser.dart';
import 'package:hibiki/src/media/video/video_import_dialog.dart';

/// EPUB extensions (lowercase, no leading dot).
const Set<String> kScanEpubExtensions = <String>{'epub'};

/// Subtitle whitelist shared with the video import dialog (no lrc).
const Set<String> kScanVideoSubtitleExts = <String>{'srt', 'vtt', 'ass', 'ssa'};

/// One pending book item: EPUB path + optional same-stem sidecar subtitle/audio.
///
/// TODO-946：当 EPUB 旁有同名字幕**且**有同名音频时，[subtitlePath] / [audioPaths]
/// 非空，扫描器据此把这本书导成有声书（字幕做对齐源 + 音频）；二者缺一则按纯
/// EPUB 导入（音频必配字幕，沿用 sidecar_finder 既有语义）。
@immutable
class ScanBookItem {
  const ScanBookItem({
    required this.epubPath,
    this.subtitlePath,
    this.audioPaths = const <String>[],
  });

  /// EPUB 文件完整路径（来源命名空间）。
  final String epubPath;

  /// 同名字幕完整路径；无同名字幕为 null。
  final String? subtitlePath;

  /// 同名（含同前缀多段）音频完整路径列表；无为空。
  final List<String> audioPaths;

  /// 是否应导成有声书：同名字幕与音频齐备（音频必配字幕）。
  bool get isAudiobook => subtitlePath != null && audioPaths.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is ScanBookItem &&
      other.epubPath == epubPath &&
      other.subtitlePath == subtitlePath &&
      _listEquals(other.audioPaths, audioPaths);

  @override
  int get hashCode =>
      Object.hash(epubPath, subtitlePath, Object.hashAll(audioPaths));
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// One pending video item: video path + associated same-stem subtitle (or null).
@immutable
class ScanVideoItem {
  const ScanVideoItem({required this.videoPath, this.subtitlePath});

  /// Full video file path (source namespace).
  final String videoPath;

  /// Associated subtitle full path; null when no same-name subtitle.
  final String? subtitlePath;

  @override
  bool operator ==(Object other) =>
      other is ScanVideoItem &&
      other.videoPath == videoPath &&
      other.subtitlePath == subtitlePath;

  @override
  int get hashCode => Object.hash(videoPath, subtitlePath);
}

/// Classification result of one scan (pure data).
@immutable
class ScanPlan {
  const ScanPlan({
    this.books = const <ScanBookItem>[],
    this.videos = const <ScanVideoItem>[],
  });

  /// Pending book items (EPUB + optional same-stem subtitle/audio sidecar).
  final List<ScanBookItem> books;

  /// Pending video items (with associated subtitles).
  final List<ScanVideoItem> videos;
}

/// Extension of an entry name (lowercase, no leading dot).
String _extOf(String name) =>
    p.extension(name).toLowerCase().replaceFirst('.', '');

/// Pure function: classifies a listed [files] set into a scan plan. No IO.
///
/// - Skips directory entries (recursive listing yields only files anyway).
/// - EPUB (ext in [kScanEpubExtensions]) -> [ScanPlan.epubPaths].
/// - Video (ext in [kVideoExtensions]) -> [ScanPlan.videos], associating the
///   same-stem subtitle found by [selectSidecarNames] within the same directory.
/// - Subtitles are not inserted on their own; they only attach to a video.
///
/// Sidecar association is scoped to the same directory: [files] are bucketed by
/// parent dir, and each video is matched against its own directory file-name set,
/// matching the import dialog's sidecar semantics.
ScanPlan planScanFromFileList(List<SourceFileEntry> files) {
  // parent dir -> all file basenames under it (for sidecar matching).
  final Map<String, List<String>> namesByDir = <String, List<String>>{};
  for (final SourceFileEntry e in files) {
    if (e.isDirectory) continue;
    final String dir = p.dirname(e.path);
    (namesByDir[dir] ??= <String>[]).add(e.name);
  }

  final List<ScanBookItem> books = <ScanBookItem>[];
  final List<ScanVideoItem> videos = <ScanVideoItem>[];

  for (final SourceFileEntry e in files) {
    if (e.isDirectory) continue;
    final String ext = _extOf(e.name);
    if (kScanEpubExtensions.contains(ext)) {
      // TODO-946：EPUB 同目录扫同名字幕 + 音频（wantAudio:true，字幕扩展含 lrc）。
      // 命中音频 -> 导成有声书（字幕作对齐源）；否则纯 EPUB。同目录作用域，与
      // 视频 sidecar 关联一致。
      final String dir = p.dirname(e.path);
      final List<String> siblings = namesByDir[dir] ?? const <String>[];
      final ({String? subtitle, List<String> audio}) sel = selectSidecarNames(
        mainFileName: e.name,
        siblingNames: siblings,
        wantAudio: true,
      );
      books.add(ScanBookItem(
        epubPath: e.path,
        subtitlePath: sel.subtitle == null ? null : p.join(dir, sel.subtitle!),
        audioPaths: sel.audio.map((String n) => p.join(dir, n)).toList(),
      ));
      continue;
    }
    if (kVideoExtensions.contains('.$ext')) {
      final String dir = p.dirname(e.path);
      final List<String> siblings = namesByDir[dir] ?? const <String>[];
      final ({String? subtitle, List<String> audio}) sel = selectSidecarNames(
        mainFileName: e.name,
        siblingNames: siblings,
        wantAudio: false,
        subtitleExts: kScanVideoSubtitleExts,
      );
      videos.add(ScanVideoItem(
        videoPath: e.path,
        subtitlePath: sel.subtitle == null ? null : p.join(dir, sel.subtitle!),
      ));
    }
  }

  return ScanPlan(books: books, videos: videos);
}

/// Source-library scanner: scans one [MediaSourceRow] root, inserts the media
/// owned by this source, and writes back the scan result.
class MediaSourceScanner {
  MediaSourceScanner(this._db) : _videoRepo = VideoBookRepository(_db);

  final HibikiDatabase _db;
  final VideoBookRepository _videoRepo;

  /// Scans one source library.
  ///
  /// [fs] defaults to [LocalSourceFileSystem] (M1b connects only locally); tests
  /// inject a local impl over a real temp dir. Routes by [MediaSourceRow.mediaKind]
  /// ('book' | 'video'):
  /// - 'book': each EPUB -> [EpubImporter.importFromPath] (with sourceId).
  /// - 'video': each video -> [VideoBookRepository.saveVideoBook] (with sourceId)
  ///   plus parsed cues when a same-name subtitle exists.
  ///
  /// After insert, calls [HibikiDatabase.updateMediaSourceScanResult] to write the
  /// media count / timestamp; any throw records its text in lastScanError
  /// (mediaCount reflects the count successfully inserted before the failure).
  Future<void> scan(
    MediaSourceRow source, {
    SourceFileSystem? fs,
  }) async {
    final SourceFileSystem files = fs ?? const LocalSourceFileSystem();
    int mediaCount = 0;
    String? scanError;
    try {
      final List<SourceFileEntry> entries = await files.listFiles(
        source.rootPath,
        recursive: source.recursive,
      );
      final ScanPlan plan = planScanFromFileList(entries);

      if (source.mediaKind == 'book') {
        mediaCount = await _importBooks(plan, source.id, files);
      } else if (source.mediaKind == 'video') {
        mediaCount = await _importVideos(plan, source.id, files);
      } else {
        throw ArgumentError.value(
          source.mediaKind,
          'mediaKind',
          'Unsupported media kind for scan (expected book | video)',
        );
      }
    } catch (e, stack) {
      scanError = e.toString();
      debugPrint('MediaSourceScanner.scan failed for '
          'source ${source.id} (${source.rootPath}): $e\n$stack');
    }

    await _db.updateMediaSourceScanResult(
      id: source.id,
      mediaCount: mediaCount,
      lastScannedAt: DateTime.now(),
      lastScanError: scanError,
    );
  }

  /// Imports every EPUB in the plan; returns the count successfully inserted.
  ///
  /// BUG-443: silent same-title dedup, mirroring [_importVideos]. Manual single-
  /// file import asks the user (or auto-suffixes to `X (2)`), but a batch folder
  /// scan must NOT re-import already-imported books as `X (2)`. We pass
  /// `skipIfExists: true` so [EpubImporter.importFromPath] reuses the existing
  /// `sanitizeTtuFilename` identity key: on a collision it throws
  /// [DuplicateImportCancelledException], which we catch per book and skip
  /// (not counted, not an error). The within-isolate parse + DB read picks up
  /// books inserted earlier in the same scan, so a same-batch duplicate is also
  /// skipped.
  Future<int> _importBooks(
    ScanPlan plan,
    int sourceId,
    SourceFileSystem fs,
  ) async {
    int count = 0;
    for (final ScanBookItem item in plan.books) {
      try {
        // skipIfExists:true reuses the sanitizeTtuFilename identity key so a
        // re-scan / same-batch duplicate throws DuplicateImportCancelledException
        // (caught below) instead of a silent "X (2)" (BUG-443). The returned
        // bookKey is the audiobook anchor when a sidecar audio attaches.
        final String bookKey = await EpubImporter.importFromPath(
          db: _db,
          filePath: item.epubPath,
          fileName: p.basename(item.epubPath),
          sourceId: sourceId,
          skipIfExists: true,
        );
        count++;
        // TODO-946：同目录有同名字幕 + 音频 -> 复用对话框抽出的非 UI 落库 service
        // 把这本 EPUB 升级成有声书（字幕做对齐源 + 音频）。仅本地传输支持（service
        // 直读磁盘路径）；网络传输的 sidecar 音频留待 M2/M3，先按纯 EPUB 导入不阻塞。
        if (item.isAudiobook && fs.isLocal) {
          await alignAndPersistAudiobook(
            db: _db,
            repo: SrtBookRepository(_db),
            audiobookRepo: AudiobookRepository(_db),
            bookKey: bookKey,
            title: p.basenameWithoutExtension(item.epubPath),
            subtitlePath: item.subtitlePath!,
            audioPaths: item.audioPaths,
          );
        }
      } on DuplicateImportCancelledException catch (e) {
        // Already-imported same-title book: silently skip (matches _importVideos).
        debugPrint('MediaSourceScanner skip duplicate book '
            '${e.title} (${item.epubPath})');
      }
    }
    return count;
  }

  /// Imports every video in the plan (with sidecar subtitle cues); returns count.
  ///
  /// [fs] is the source file system the scan listed from. Subtitles are read via
  /// [SourceFileSystem.copyToLocal] (local = original path unchanged; network =
  /// downloaded to a temp dir) then decoded with [readTextWithEncoding] so the
  /// SJIS/CP932/EUC-JP charset detection used by the manual import path is
  /// preserved (TODO-817 M1b TODO②). Covers are extracted via [extractVideoCover]
  /// (TODO-817 M1b TODO①); ffmpeg failure / mobile simply yields a null cover and
  /// the video still imports (shelf shows a placeholder).
  Future<int> _importVideos(
    ScanPlan plan,
    int sourceId,
    SourceFileSystem fs,
  ) async {
    if (plan.videos.isEmpty) return 0;
    // Existing book_uid set for silent same-name dedup (matches import dialog).
    final Set<String> existingKeys =
        (await _videoRepo.listAll()).map((VideoBookRow r) => r.bookUid).toSet();

    // Temp dir only used by non-local transports (copyToLocal downloads here);
    // for local transport copyToLocal returns the original path unchanged.
    Directory? subtitleTmp;

    try {
      int count = 0;
      for (final ScanVideoItem item in plan.videos) {
        final String bookUid = uniqueVideoBookUid(
          singleVideoBookUid(item.videoPath),
          existingKeys,
        );
        existingKeys.add(bookUid);

        String? subtitleSource;
        String? subtitleFormat;
        List<AudioCue> cues = const <AudioCue>[];
        if (item.subtitlePath != null) {
          final String fmt = _extOf(p.basename(item.subtitlePath!));
          subtitleTmp ??= Directory.systemTemp.createTempSync('m1c_scan_subs_');
          final String localSub =
              await fs.copyToLocal(item.subtitlePath!, subtitleTmp.path);
          // readTextWithEncoding(File) keeps the non-UTF-8 charset detection;
          // local copyToLocal returns the original path so behaviour is unchanged.
          final String content = await readTextWithEncoding(File(localSub));
          cues = parseSubtitleCues(
            content: content,
            format: fmt,
            bookUid: bookUid,
          );
          subtitleSource = item.subtitlePath;
          subtitleFormat = fmt;
        }

        // Cover only for local files (extractVideoCover needs a local path);
        // network cover extraction is deferred to M2/M3. Cover is an OPTIONAL
        // enhancement: ffmpeg-missing returns null, and any unexpected failure
        // (e.g. path_provider unavailable) must never abort the whole scan, so
        // it is caught here and degrades to a null cover (shelf placeholder).
        String? coverPath;
        if (fs.isLocal) {
          try {
            coverPath = await extractVideoCover(
              videoPath: item.videoPath,
              bookUid: bookUid,
            );
          } catch (e) {
            debugPrint('MediaSourceScanner cover extract failed for '
                '$bookUid: $e');
          }
        }

        await _videoRepo.saveVideoBook(
          VideoBooksCompanion(
            bookUid: Value(bookUid),
            title: Value(p.basenameWithoutExtension(item.videoPath)),
            videoPath: Value(item.videoPath),
            coverPath: Value<String?>(coverPath),
            subtitleSource: Value<String?>(subtitleSource),
            subtitleFormat: Value<String?>(subtitleFormat),
            embeddedSubtitleTrack: subtitleSource == null
                ? const Value<int?>(0)
                : const Value<int?>(null),
            importedAt: Value(DateTime.now()),
          ),
          sourceId: sourceId,
        );
        if (cues.isNotEmpty) {
          await _videoRepo.saveCues(bookUid: bookUid, cues: cues);
        }
        count++;
      }
      return count;
    } finally {
      if (subtitleTmp != null) {
        try {
          subtitleTmp.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  }
}
