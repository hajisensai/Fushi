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
// TODO-1274: network transport (SFTP/FTP/WebDAV) is now wired for BOOK sources —
// the transport is resolved from the row (local vs SFTP/FTP/WebDAV built from
// configJson + MediaSourceCredentialStore), and remote EPUBs are downloaded via
// copyToLocal before import. Routing is transport-agnostic here: any non-'local'
// transport builds a NetworkSourceFileSystem which dispatches SFTP/FTP/WebDAV
// internally, so [buildNetworkFileSystem] needs no per-transport branch. Network
// VIDEO sources are rejected (a raw remote path is not playable). Existing manual
// import paths (dialogs) are untouched; sourceId defaults to null.

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/src/epub/book_title_conflict.dart';
import 'package:hibiki/src/epub/epub_importer.dart';
import 'package:hibiki/src/media/audiobook/audiobook_alignment_service.dart';
import 'package:hibiki/src/media/drag_drop/drop_classification.dart'
    show kDragPlaylistExtensions;
import 'package:hibiki/src/media/import/sidecar_finder.dart';
import 'package:hibiki/src/media/source/media_source_credential_store.dart';
import 'package:hibiki/src/media/source/source_file_system.dart';
import 'package:hibiki/src/media/video/external_video.dart'
    show normalizeVideoPath;
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/media/video/m3u8_playlist.dart';
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

/// One pending playlist item: an m3u8/m3u manifest scanned in a video source.
///
/// TODO-1237: folder scan treats `.m3u8`/`.m3u` as multi-episode playlist
/// manifests, same semantics as the drag-drop path (kDragPlaylistExtensions /
/// DropIntent.importNewPlaylist): not a single video file but a parseM3u8'd
/// episode list persisted as one playlist VideoBook.
@immutable
class ScanPlaylistItem {
  const ScanPlaylistItem({required this.playlistPath});

  /// Full m3u8/m3u file path (source namespace).
  final String playlistPath;

  @override
  bool operator ==(Object other) =>
      other is ScanPlaylistItem && other.playlistPath == playlistPath;

  @override
  int get hashCode => playlistPath.hashCode;
}

/// Classification result of one scan (pure data).
@immutable
class ScanPlan {
  const ScanPlan({
    this.books = const <ScanBookItem>[],
    this.videos = const <ScanVideoItem>[],
    this.playlists = const <ScanPlaylistItem>[],
  });

  /// Pending book items (EPUB + optional same-stem subtitle/audio sidecar).
  final List<ScanBookItem> books;

  /// Pending video items (with associated subtitles).
  final List<ScanVideoItem> videos;

  /// Pending playlist items (m3u8/m3u multi-episode manifests, TODO-1237).
  final List<ScanPlaylistItem> playlists;
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
  // parent dir -> {basename: original full path} (for sidecar path lookup).
  // TODO-1274: sidecar full paths are looked up here, NOT rebuilt via
  // p.join(dir, name), so a remote source's forward-slash paths survive on a
  // Windows host (p.join would inject backslashes).
  final Map<String, Map<String, String>> pathByDir =
      <String, Map<String, String>>{};
  for (final SourceFileEntry e in files) {
    if (e.isDirectory) continue;
    final String dir = p.dirname(e.path);
    (namesByDir[dir] ??= <String>[]).add(e.name);
    (pathByDir[dir] ??= <String, String>{})[e.name] = e.path;
  }

  final List<ScanBookItem> books = <ScanBookItem>[];
  final List<ScanVideoItem> videos = <ScanVideoItem>[];
  final List<ScanPlaylistItem> playlists = <ScanPlaylistItem>[];

  for (final SourceFileEntry e in files) {
    if (e.isDirectory) continue;
    final String ext = _extOf(e.name);
    // TODO-1237: m3u8/m3u playlist manifest, reusing the drag-drop path's own
    // [kDragPlaylistExtensions] whitelist. Checked before the video branch
    // (m3u8 is not in kVideoExtensions, the two are disjoint; ordering is only
    // for clarity).
    if (kDragPlaylistExtensions.contains(ext)) {
      playlists.add(ScanPlaylistItem(playlistPath: e.path));
      continue;
    }
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
      final Map<String, String> dirPaths =
          pathByDir[dir] ?? const <String, String>{};
      books.add(ScanBookItem(
        epubPath: e.path,
        subtitlePath: sel.subtitle == null ? null : dirPaths[sel.subtitle!],
        audioPaths: sel.audio.map((String n) => dirPaths[n] ?? n).toList(),
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
      final Map<String, String> dirPaths =
          pathByDir[dir] ?? const <String, String>{};
      videos.add(ScanVideoItem(
        videoPath: e.path,
        subtitlePath: sel.subtitle == null ? null : dirPaths[sel.subtitle!],
      ));
    }
  }

  return ScanPlan(books: books, videos: videos, playlists: playlists);
}

/// Source-library scanner: scans one [MediaSourceRow] root, inserts the media
/// owned by this source, and writes back the scan result.
class MediaSourceScanner {
  MediaSourceScanner(this._db) : _videoRepo = VideoBookRepository(_db);

  final HibikiDatabase _db;
  final VideoBookRepository _videoRepo;

  /// 从来源行解析文件系统：local → LocalSourceFileSystem；网络 → 解出连接参数
  /// （configJson）+ 凭据（MediaSourceCredentialStore）构造 NetworkSourceFileSystem。
  Future<SourceFileSystem> _resolveFileSystem(MediaSourceRow source) async {
    if (source.transport == 'local') {
      return const LocalSourceFileSystem();
    }
    final MediaSourceSecret secret =
        await MediaSourceCredentialStore(_db).readSecret(source.id);
    return buildNetworkFileSystem(
      transport: source.transport,
      config: decodeSourceConfig(source.configJson),
      password: secret.password,
      privateKey: secret.privateKey,
    );
  }

  /// 纯构造：把 transport + 连接参数 + 凭据组装成 [SourceFileSystem]（无 I/O）。
  /// 抽出供测试断言路由正确。WebDAV 的 host/port/useTls 不参与传输（URL 即 rootPath，
  /// 自带 scheme/host/端口），此处仍原样填入仅为字段对齐，NetworkSourceFileSystem 忽略。
  @visibleForTesting
  static SourceFileSystem buildNetworkFileSystem({
    required String transport,
    required Map<String, Object?> config,
    String? password,
    String? privateKey,
  }) {
    if (transport == 'local') {
      return const LocalSourceFileSystem();
    }
    final int port =
        (config['port'] as num?)?.toInt() ?? (transport == 'sftp' ? 22 : 21);
    return NetworkSourceFileSystem(NetworkSourceConfig(
      transport: transport,
      host: (config['host'] as String?) ?? '',
      port: port,
      username: (config['username'] as String?) ?? '',
      password: (password != null && password.isNotEmpty) ? password : null,
      privateKey:
          (privateKey != null && privateKey.isNotEmpty) ? privateKey : null,
      useTls: (config['useTls'] as bool?) ?? false,
    ));
  }

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
    final SourceFileSystem files = fs ?? await _resolveFileSystem(source);
    int mediaCount = 0;
    String? scanError;
    try {
      // 网络视频来源不受支持：远端 SFTP/FTP 路径不可被播放器直接播放（只支持网络
      // 「书」来源——EPUB 小体积、扫描时下载后导入）。
      if (!files.isLocal && source.mediaKind == 'video') {
        throw StateError('Network video sources are not supported');
      }
      final List<SourceFileEntry> entries = await files.listFiles(
        source.rootPath,
        recursive: source.recursive,
      );
      final ScanPlan plan = planScanFromFileList(entries);

      if (source.mediaKind == 'book') {
        mediaCount = await _importBooks(plan, source.id, files);
      } else if (source.mediaKind == 'video') {
        // Video source imports both single videos and m3u8/m3u playlists
        // (TODO-1237).
        mediaCount = await _importVideos(plan, source.id, files);
        mediaCount += await _importPlaylists(plan, source.id, files);
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
    } finally {
      // 关闭网络连接（本地/注入的 fake 无需关闭）。
      if (files is NetworkSourceFileSystem) {
        await files.close();
      }
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
    Directory? epubTmp;
    for (final ScanBookItem item in plan.books) {
      try {
        // 网络来源：先把远端 EPUB 下载到临时盘（导入器只吃本地路径）；本地原样。
        String localEpub = item.epubPath;
        if (!fs.isLocal) {
          epubTmp ??= Directory.systemTemp.createTempSync('m1c_scan_books_');
          localEpub = await fs.copyToLocal(item.epubPath, epubTmp.path);
        }
        // skipIfExists:true reuses the sanitizeTtuFilename identity key so a
        // re-scan / same-batch duplicate throws DuplicateImportCancelledException
        // (caught below) instead of a silent "X (2)" (BUG-443). The returned
        // bookKey is the audiobook anchor when a sidecar audio attaches.
        final String bookKey = await EpubImporter.importFromPath(
          db: _db,
          filePath: localEpub,
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
        // TODO-1284：书已导入过。纯重扫时静默跳过是对的（对齐 _importVideos），但若
        // 首次导入后才把同名字幕+音频放到书旁边（书当初是按纯 EPUB 导入的），重扫必须
        // 把它补挂成有声书——否则新增的 .srt/.mp3 被静默忽略。仅当该书尚未挂任何有声书
        // 时才对齐，保证重复重扫幂等、不重跑 matcher、不覆盖用户手动重匹配。
        await _attachSidecarAudiobookToExisting(item, e.title, fs);
        debugPrint('MediaSourceScanner skip duplicate book '
            '${e.title} (${item.epubPath})');
      }
    }
    if (epubTmp != null) {
      try {
        epubTmp.deleteSync(recursive: true);
      } catch (_) {}
    }
    return count;
  }

  /// TODO-1284：重扫时把「首次导入后才新增到书旁的同名字幕+音频」补挂成有声书。
  ///
  /// [title] 是 [DuplicateImportCancelledException] 携带的冲突标题，其身份 key
  /// （[sanitizeTtuFilename]）即已存在书的 bookKey。仅当本次扫描项确有 sidecar
  /// 字幕+音频（[ScanBookItem.isAudiobook]）、传输为本地（service 直读磁盘路径）、
  /// 该 bookKey 的书确实在库、且尚未挂任何有声书时才对齐落库；已挂则跳过，保证重扫
  /// 幂等、不重跑 matcher、不覆盖用户手动重匹配。
  Future<void> _attachSidecarAudiobookToExisting(
    ScanBookItem item,
    String title,
    SourceFileSystem fs,
  ) async {
    if (!item.isAudiobook || !fs.isLocal) return;
    final String bookKey = sanitizeTtuFilename(title);
    final EpubBookRow? existingBook = await _db.getEpubBook(bookKey);
    if (existingBook == null) return;
    final AudiobookRepository audiobookRepo = AudiobookRepository(_db);
    final Audiobook? alreadyAttached =
        await audiobookRepo.findByBookKey(bookKey);
    if (alreadyAttached != null) return;
    await alignAndPersistAudiobook(
      db: _db,
      repo: SrtBookRepository(_db),
      audiobookRepo: audiobookRepo,
      bookKey: bookKey,
      title: p.basenameWithoutExtension(item.epubPath),
      subtitlePath: item.subtitlePath!,
      audioPaths: item.audioPaths,
    );
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
    final List<VideoBookRow> existingRows = await _videoRepo.listAll();
    // Existing book_uid set for silent same-name dedup (matches import dialog).
    final Set<String> existingKeys =
        existingRows.map((VideoBookRow r) => r.bookUid).toSet();
    // TODO-1237 ②: existing physical paths (normalized) for re-scan dedup — a
    // folder re-scan must SKIP files already imported instead of suffixing
    // `X (2)` duplicates (mirrors _importBooks' skipIfExists, BUG-443). Grown as
    // we insert so a same-batch duplicate path is skipped too.
    final Set<String> existingPaths = existingRows
        .map((VideoBookRow r) => normalizeVideoPath(r.videoPath))
        .toSet();

    // Temp dir only used by non-local transports (copyToLocal downloads here);
    // for local transport copyToLocal returns the original path unchanged.
    Directory? subtitleTmp;

    try {
      int count = 0;
      for (final ScanVideoItem item in plan.videos) {
        // Skip already-imported physical files (library or same-batch dup).
        if (!existingPaths.add(normalizeVideoPath(item.videoPath))) {
          continue;
        }
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

  /// Imports every m3u8/m3u playlist in the plan into a playlist VideoBook;
  /// returns the count successfully inserted (TODO-1237).
  ///
  /// Mirrors the dialog's manual / drag-drop playlist import but headless:
  /// [parseM3u8] parses the manifest (episode paths resolved via
  /// [resolveM3uEntryPath]: relative -> the m3u8's own dir, absolute /
  /// backslash / UNC handled), then splits it into N independent per-episode
  /// VideoBook rows + one `'playlist'` [MediaCollections] (统一合集 Phase 2, via
  /// [VideoBookRepository.importSplitPlaylist], byte-aligned with the v38
  /// migration).
  ///
  /// Re-scan dedup: there is no single playlist row to key on any more, so the
  /// manifest is deduped on whether its FIRST episode's path is already imported
  /// ([VideoBookRepository.isVideoPathReferenced], same key the dialog folder
  /// import uses) — a re-scan of an already-imported folder skips it. Unlike the
  /// old first-episode key this now runs after parse (parsing a small manifest
  /// on re-scan is cheap); correctness of idempotency wins over the micro-cost.
  ///
  /// [fs] is the source file system: the manifest is read via
  /// [SourceFileSystem.copyToLocal] (local = original path unchanged; network =
  /// downloaded to a temp dir) then decoded with [readTextWithEncoding], reusing
  /// the same charset detection as [_importVideos]. Cover extraction needs a
  /// local path so it only runs for local transport (like [_importVideos]) and
  /// is applied to the first episode; ffmpeg-missing / any failure degrades to a
  /// null cover (shelf placeholder) and never aborts the scan. An empty /
  /// unparsable manifest inserts nothing (skipped, not counted, not an error).
  /// Returns the number of playlists (collections) newly imported.
  Future<int> _importPlaylists(
    ScanPlan plan,
    int sourceId,
    SourceFileSystem fs,
  ) async {
    if (plan.playlists.isEmpty) return 0;

    // 统一合集：拆集后无单条 playlist 行 → 用「同名 playlist 合集是否已存在」区分
    // 首次导入 vs 重扫。合集名 = m3u8 basename（**不随 manifest 内集路径编辑而变** →
    // 编辑集路径重扫仍幂等，不产生 X (2) 重复，TODO-1237 ②）。首导（不存在）走
    // importSplitPlaylist；已存在走 reconcileSplitPlaylist 把成员对齐到当前清单
    // （BUG-830：磁盘上编辑 m3u8 增删某集后合集成员永不更新）。故必须逐个解析清单
    // （不再「同名即整体跳过」），per-playlist 多读一个小文本清单的开销可接受。
    final Map<String, int> existingPlaylistIds = <String, int>{
      for (final MediaCollectionRow c in await _db.getAllMediaCollections())
        if (c.collectionType == 'playlist') c.name: c.id,
    };

    // Temp dir only used by non-local transports (copyToLocal downloads here);
    // for local transport copyToLocal returns the original path unchanged.
    Directory? playlistTmp;
    try {
      int count = 0;
      for (final ScanPlaylistItem item in plan.playlists) {
        final String collectionName =
            p.basenameWithoutExtension(item.playlistPath);

        playlistTmp ??= Directory.systemTemp.createTempSync('m1c_scan_pls_');
        final String localM3u8 =
            await fs.copyToLocal(item.playlistPath, playlistTmp.path);
        final String content = await readTextWithEncoding(File(localM3u8));
        // baseDir is the ORIGINAL m3u8 path's directory (source namespace):
        // locally the real on-disk dir, matching manual / drag-drop import when
        // resolving relative episode paths.
        final String baseDir = p.dirname(item.playlistPath);
        final List<PlaylistEntry> entries =
            parseM3u8(content: content, baseDir: baseDir);
        // 空 / 不可解析清单：跳过（不当成「清单变空 → 清光成员」，避免读盘瞬时失败
        // 误删已存在合集，保守降级）。
        if (entries.isEmpty) continue;

        final int? existingId = existingPlaylistIds[collectionName];
        if (existingId != null) {
          // 已存在同名 playlist 合集：以当前清单为准对齐成员（增删差异），不重导、
          // 不计入「新增合集数」；封面首导时已抽，无需重抽。
          await _videoRepo.reconcileSplitPlaylist(
            collectionId: existingId,
            entries: entries,
            sourceId: sourceId,
          );
          continue;
        }

        final ({int collectionId, List<String> episodeUids}) result =
            await _videoRepo.importSplitPlaylist(
          collectionName: collectionName,
          entries: entries,
          sourceId: sourceId,
        );
        // 记入 map：同一次扫描里遇到第二个同名清单时走 reconcile，不再重导致重复。
        existingPlaylistIds[collectionName] = result.collectionId;

        // TODO-1237 ①: cover from the first USABLE episode (local ffmpeg only),
        // applied to the first episode row; mobile / any failure -> null cover,
        // never aborts the scan.
        if (fs.isLocal) {
          try {
            final String? coverPath = await extractPlaylistCover(
              episodePaths: entries.map((PlaylistEntry e) => e.path).toList(),
              bookUid: result.episodeUids.first,
            );
            if (coverPath != null) {
              await _videoRepo.updateCover(result.episodeUids.first, coverPath);
            }
          } catch (e) {
            debugPrint('MediaSourceScanner playlist cover extract failed for '
                '${result.collectionId}: $e');
          }
        }
        count++;
      }
      return count;
    } finally {
      if (playlistTmp != null) {
        try {
          playlistTmp.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  }
}
