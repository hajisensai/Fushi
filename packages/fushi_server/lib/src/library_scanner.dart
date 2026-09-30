/// 服务端库扫描：把配置里的 `libraries[]` 目录树落进服务端自己的 DB。
///
/// 与 app 的 `SourceLibraryScanner` 走同一条入库路径（`VideoBookRepository` /
/// `EpubImporter`），所以客户端经 `/api/library/videos` / `/books` 看到的行与
/// 本机导入的一模一样。漫画根（kind=manga）走引擎 `MangaImporter`：`.mokuro`
/// 卷与纯页图目录，卷归组规则与 app 共用引擎 `planMangaFolders`。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/manga/manga_folder_plan.dart';
import 'package:fushi_engine/media/manga/manga_importer.dart';
import 'package:fushi_engine/media/media_extensions.dart';
import 'package:fushi_engine/media/video/external_video.dart'
    show normalizeVideoPath;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_cover_extractor.dart';
import 'package:fushi_engine/media/video/video_library_import.dart';
import 'package:fushi_engine/media/video/video_library_prune.dart';
import 'package:fushi_engine/media/video/video_sidecar.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:path/path.dart' as p;

class ScanSummary {
  int videosAdded = 0;
  int videosSkipped = 0;
  int booksAdded = 0;
  int booksSkipped = 0;
  int mangaAdded = 0;
  int mangaSkipped = 0;

  /// 扫描对账回收的失效视频条目数（行还在、文件已消失）。
  int videosPruned = 0;

  /// 被护栏（库根不存在 / 失效占比过高）或刮削租约拦下的库根数。
  int pruneSkipped = 0;

  /// 对账相关的说明（护栏拦下原因等），与 [errors] 分开：这些不是失败。
  final List<String> pruneNotes = <String>[];
  final List<String> errors = <String>[];

  @override
  String toString() => 'videos +$videosAdded (skipped $videosSkipped, pruned $videosPruned), '
      'books +$booksAdded (skipped $booksSkipped), '
      'manga +$mangaAdded (skipped $mangaSkipped), errors ${errors.length}'
      '${pruneSkipped > 0 ? ', prune-skipped $pruneSkipped' : ''}';
}

class LibraryScanner {
  LibraryScanner({
    required this.db,
    required this.subtitleLanguage,
    this.extractCovers = true,
    this.pruneMissing = true,
    this.pruneThreshold = const VideoPruneThreshold(),
    this.pruneForce = false,
  }) : _videos = VideoBookRepository(db);

  final FushiDatabase db;
  final String subtitleLanguage;
  final bool extractCovers;

  /// 扫描后是否对账回收「文件已消失」的视频条目（默认开）。
  ///
  /// 关掉只是不做清理，导入行为一个字不变；但库里会继续留着失效条目。
  final bool pruneMissing;
  final VideoPruneThreshold pruneThreshold;

  /// 越过护栏阈值也照删（危险：库根整体不可达时会批量误删）。
  final bool pruneForce;
  final VideoBookRepository _videos;

  Future<ScanSummary> scanAll(List<LibraryRootConfig> roots) async {
    final ScanSummary summary = ScanSummary();
    for (final LibraryRootConfig root in roots) {
      if (!root.enabled) continue;
      final Directory dir = Directory(root.path);
      if (!await dir.exists()) {
        summary.errors.add('${root.id}: 目录不存在 ${root.path}');
        continue;
      }
      switch (root.kind) {
        case 'video':
          final Set<String> found = await _scanVideos(dir, summary);
          if (pruneMissing) await _pruneVideoRoot(dir, root.id, found, summary);
        case 'book':
          await _scanBooks(dir, summary);
          _noteUnreconciled(root.id, 'book');
        case 'manga':
          await _scanManga(dir, summary);
          _noteUnreconciled(root.id, 'manga');
        default:
          summary.errors.add('${root.id}: 未支持的 kind "${root.kind}"（只有 video / book / manga）');
      }
    }
    engineLog.logDiagnostic('LibraryScanner', 'scan done: $summary');
    return summary;
  }

  /// 扫描一个视频根，返回**磁盘上现存**的视频文件路径集合（归一），供对账复用。
  Future<Set<String>> _scanVideos(Directory dir, ScanSummary summary) async {
    final List<File> files = <File>[];
    await for (final FileSystemEntity e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      if (!_isVideo(e.path)) continue;
      files.add(e);
    }
    files.sort((File a, File b) => a.path.compareTo(b.path));
    final List<VideoBookRow> existingRows = await _videos.listAll();
    final Set<String> existingKeys =
        existingRows.map((VideoBookRow r) => r.bookUid).toSet();
    // 物理路径集合一次算好、循环内查集合。此前逐文件调 `isDuplicateVideoPath`
    // （它内部每次都 `listAll()` 全表读），整个扫描是 O(n²)。比对语义与
    // `VideoBookRepository.isDuplicateVideoPath` 一致：两侧都 [normalizeVideoPath]。
    final Set<String> existingPaths = <String>{
      for (final VideoBookRow r in existingRows)
        if (r.videoPath.isNotEmpty) normalizeVideoPath(r.videoPath),
    };
    final Set<String> found = <String>{};
    for (final File file in files) {
      final String normalized = normalizeVideoPath(file.path);
      found.add(normalized);
      try {
        if (!existingPaths.add(normalized)) {
          summary.videosSkipped++;
          continue;
        }
        final String bookUid =
            uniqueVideoBookUid(singleVideoBookUid(file.path), existingKeys);
        existingKeys.add(bookUid);
        final String? sidecar =
            findSidecarSubtitle(file.path, langCode: subtitleLanguage);
        final String? subtitleFormat = sidecar == null
            ? null
            : p.extension(sidecar).replaceFirst('.', '').toLowerCase();
        await _videos.saveVideoBook(VideoBooksCompanion(
          bookUid: Value(bookUid),
          title: Value(p.basenameWithoutExtension(file.path)),
          videoPath: Value(file.path),
          subtitleSource: Value<String?>(sidecar),
          subtitleFormat: Value<String?>(subtitleFormat),
          embeddedSubtitleTrack:
              sidecar == null ? const Value<int?>(0) : const Value<int?>(null),
          importedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ));
        summary.videosAdded++;
        if (extractCovers) {
          final String? cover = await extractVideoCover(
            videoPath: file.path,
            bookUid: bookUid,
          );
          if (cover != null) await _videos.updateCover(bookUid, cover);
        }
      } catch (e, stack) {
        summary.errors.add('${file.path}: $e');
        engineLog.log('LibraryScanner.video', e, stack);
      }
    }
    return found;
  }

  /// 对一个视频根做一次对账（见 [pruneMissingVideoRows]）。
  ///
  /// 护栏 / 刮削租约拦下只记 note，不算错误：扫描因环境暂时无法安全清理，不是失败。
  Future<void> _pruneVideoRoot(
    Directory dir,
    String rootId,
    Set<String> found,
    ScanSummary summary,
  ) async {
    final VideoPruneReport report = await pruneMissingVideoRows(
      repository: _videos,
      root: dir,
      foundPaths: found,
      threshold: pruneThreshold,
      force: pruneForce,
    );
    if (report.skipped) {
      summary.pruneSkipped++;
      summary.pruneNotes.add('$rootId: ${report.skipReason}');
      engineLog.logDiagnostic(
        'LibraryScanner.prune',
        '$rootId: skipped (${report.skipReason})',
      );
      return;
    }
    summary.videosPruned += report.deleted;
    if (report.missing > 0) {
      engineLog.logDiagnostic(
        'LibraryScanner.prune',
        '$rootId: removed ${report.deleted} of ${report.missing} stale video row(s)',
      );
    }
    for (final String e in report.errors) {
      summary.errors.add('$rootId: prune: $e');
      engineLog.logDiagnostic('LibraryScanner.prune', '$rootId: $e');
    }
  }

  /// 书 / 漫画根的导入会把正文拷进 `<documents>/fushi_books/<bookKey>/`，行里
  /// **没有记录源文件路径**，因此判不出源文件是否已被删掉——本轮不对账。这里如实
  /// 留痕，而不是让它看起来「已经管了」。
  static void _noteUnreconciled(String rootId, String kind) {
    engineLog.logDiagnostic(
      'LibraryScanner.prune',
      '$rootId: $kind root is not reconciled (source path not recorded)',
    );
  }

  Future<void> _scanBooks(Directory dir, ScanSummary summary) async {
    await for (final FileSystemEntity e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File || p.extension(e.path).toLowerCase() != '.epub') continue;
      try {
        await EpubImporter.importFromPath(
          db: db,
          filePath: e.path,
          fileName: p.basename(e.path),
          policy: const DuplicatePolicy.skip(),
        );
        summary.booksAdded++;
      } on DuplicateImportCancelledException {
        summary.booksSkipped++;
      } catch (err, stack) {
        summary.errors.add('${e.path}: $err');
        engineLog.log('LibraryScanner.book', err, stack);
      }
    }
  }

  /// 漫画根：先逐个导入 `.mokuro` 卷，再把引擎归组出的纯页图卷目录逐个导入
  /// （标题 = 目录名，与 app 源库扫描同口径）。重复卷按标题身份静默跳过；单卷
  /// 失败只记错误，不中断整批。
  ///
  /// cbz / cbr / pdf 本轮不做：压缩包导入器（`MangaArchiveImporter`）还在 app 侧
  /// 且 rar/cb7 依赖外部 7-Zip；等它下沉进引擎再接。
  Future<void> _scanManga(Directory dir, ScanSummary summary) async {
    final MangaFolderPlan plan = planMangaFoldersInDirectory(dir);
    for (final String mokuroPath in plan.mokuroPaths) {
      await _importManga(
        summary,
        mokuroPath,
        () => MangaImporter.importFromMokuroPath(
          db: db,
          mokuroPath: mokuroPath,
          policy: const DuplicatePolicy.skip(),
        ),
      );
    }
    for (final String folder in plan.imageFolders) {
      await _importManga(
        summary,
        folder,
        () => MangaImporter.importFromImageFolder(
          db: db,
          imageDirPath: folder,
          title: p.basename(folder),
          policy: const DuplicatePolicy.skip(),
        ),
      );
    }
  }

  Future<void> _importManga(
    ScanSummary summary,
    String sourcePath,
    Future<String> Function() import,
  ) async {
    try {
      await import();
      summary.mangaAdded++;
    } on DuplicateImportCancelledException {
      summary.mangaSkipped++;
    } catch (err, stack) {
      summary.errors.add('$sourcePath: $err');
      engineLog.log('LibraryScanner.manga', err, stack);
    }
  }

  static bool _isVideo(String path) {
    final String ext = p.extension(path).toLowerCase();
    return kVideoExtensions.contains(ext) ||
        kVideoExtensions.contains(ext.replaceFirst('.', ''));
  }
}
