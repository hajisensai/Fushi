/// 服务端库扫描：把配置里的 `libraries[]` 目录树落进服务端自己的 DB。
///
/// 与 app 的 `SourceLibraryScanner` 走同一条入库路径（`VideoBookRepository` /
/// `EpubImporter`），所以客户端经 `/api/library/videos` / `/books` 看到的行与
/// 本机导入的一模一样。第 0 期只做视频与 EPUB；漫画目录的扫描留给漫画域接入
/// （引擎里的 `MangaImporter` 已在，接线时补）。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
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
  final List<String> errors = <String>[];

  @override
  String toString() => 'videos +$videosAdded (skipped $videosSkipped), '
      'books +$booksAdded (skipped $booksSkipped), errors ${errors.length}';
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
        default:
          summary.errors.add('${root.id}: 未支持的 kind "${root.kind}"（第 0 期只有 video / book）');
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

  static bool _isVideo(String path) {
    final String ext = p.extension(path).toLowerCase();
    return kVideoExtensions.contains(ext) ||
        kVideoExtensions.contains(ext.replaceFirst('.', ''));
  }
}
