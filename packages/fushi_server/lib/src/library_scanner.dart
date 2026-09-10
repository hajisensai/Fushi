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
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_cover_extractor.dart';
import 'package:fushi_engine/media/video/video_library_import.dart';
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
  final List<String> errors = <String>[];

  @override
  String toString() => 'videos +$videosAdded (skipped $videosSkipped), '
      'books +$booksAdded (skipped $booksSkipped), '
      'manga +$mangaAdded (skipped $mangaSkipped), errors ${errors.length}';
}

class LibraryScanner {
  LibraryScanner({
    required this.db,
    required this.subtitleLanguage,
    this.extractCovers = true,
  }) : _videos = VideoBookRepository(db);

  final FushiDatabase db;
  final String subtitleLanguage;
  final bool extractCovers;
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
          await _scanVideos(dir, summary);
        case 'book':
          await _scanBooks(dir, summary);
        case 'manga':
          await _scanManga(dir, summary);
        default:
          summary.errors.add('${root.id}: 未支持的 kind "${root.kind}"（只有 video / book / manga）');
      }
    }
    engineLog.logDiagnostic('LibraryScanner', 'scan done: $summary');
    return summary;
  }

  Future<void> _scanVideos(Directory dir, ScanSummary summary) async {
    final List<File> files = <File>[];
    await for (final FileSystemEntity e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      if (!_isVideo(e.path)) continue;
      files.add(e);
    }
    files.sort((File a, File b) => a.path.compareTo(b.path));
    final Set<String> existingKeys = (await _videos.listAll())
        .map((VideoBookRow r) => r.bookUid)
        .toSet();
    for (final File file in files) {
      try {
        if (await _videos.isDuplicateVideoPath(file.path)) {
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
