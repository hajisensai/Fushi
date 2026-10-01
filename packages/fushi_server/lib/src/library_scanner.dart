/// 服务端库扫描：把配置里的 `libraries[]` 目录树落进服务端自己的 DB。
///
/// 与 app 的 `SourceLibraryScanner` 走同一条入库路径（`VideoBookRepository` /
/// `EpubImporter`），所以客户端经 `/api/library/videos` / `/books` 看到的行与
/// 本机导入的一模一样。漫画根（kind=manga）走引擎 `MangaImporter`：`.mokuro`
/// 卷与纯页图目录，卷归组规则与 app 共用引擎 `planMangaFolders`。
///
/// 书 / 漫画根同样登记一行 `media_sources`（kind = book / manga），入库行带 `sourceId`，
/// 并在来源扫描索引（引擎 `BookSourceIndex`）里记下「源相对路径 → 书 uid」——书 / 漫画
/// 导入会把正文拷进 `fushi_books/`，行里记不住源文件，没有这张索引就判不出源文件被删。
///
/// 视频根与 app 的本地视频来源同构：每个根登记一行 `media_sources`（本地、递归），
/// 入库行带 `sourceId`，入库后按引擎 `VideoFolderGroupCoordinator` 把分集归成作品
/// 合集、`VideoSourceMetadataIndexer` 吃进 NFO。刮削计划器（`VideoSourceWorkPlanner`）
/// 只认「带 sourceId 的行 + 合集成员关系」，以前服务端扫描两样都不写，所以扫进来的
/// 视频永远规划不出作品、也就永远不会被刮削。
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
import 'package:fushi_engine/media/source_library/book_library_prune.dart';
import 'package:fushi_engine/media/source_library/library_prune_guard.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/external_video.dart'
    show normalizeVideoPath;
import 'package:fushi_engine/media/video/metadata/video_source_metadata_indexer.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_cover_extractor.dart';
import 'package:fushi_engine/media/video/video_folder_group_coordinator.dart';
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

  /// 扫描对账回收的失效书 / 漫画卷数（源文件已消失）。
  int booksPruned = 0;
  int mangaPruned = 0;

  /// 被护栏（库根不存在 / 失效占比过高）或刮削租约拦下的库根数。
  int pruneSkipped = 0;

  /// 对账相关的说明（护栏拦下原因等），与 [errors] 分开：这些不是失败。
  final List<String> pruneNotes = <String>[];
  final List<String> errors = <String>[];

  @override
  String toString() => 'videos +$videosAdded (skipped $videosSkipped, pruned $videosPruned), '
      'books +$booksAdded (skipped $booksSkipped${booksPruned > 0 ? ', pruned $booksPruned' : ''}), '
      'manga +$mangaAdded (skipped $mangaSkipped${mangaPruned > 0 ? ', pruned $mangaPruned' : ''}), errors ${errors.length}'
      '${pruneSkipped > 0 ? ', prune-skipped $pruneSkipped' : ''}';
}

/// 一个书 / 漫画根的扫描产物：来源、索引、磁盘上现存的源（索引键形态）与导入前已被
/// 认领的书 uid（对账基线）。
class _BookScan {
  _BookScan({required this.source, required this.index, required this.found, required this.baselineUids});

  final SourceLibraryRow source;
  final BookSourceIndex index;
  final Set<String> found;
  final Set<String> baselineUids;
}

/// 一个视频根的扫描产物：磁盘上现存的归一路径 + 导入前已在库的行 uid（对账基线）。
class _VideoScan {
  _VideoScan({required this.found, required this.baselineBookUids});

  final Set<String> found;
  final Set<String> baselineBookUids;
}

class LibraryScanner {
  LibraryScanner({
    required this.db,
    required this.subtitleLanguage,
    this.extractCovers = true,
    this.pruneMissing = true,
    this.pruneThreshold = const LibraryPruneThreshold(),
    this.pruneForce = false,
  }) : _videos = VideoBookRepository(db);

  final FushiDatabase db;
  final String subtitleLanguage;
  final bool extractCovers;

  /// 扫描后是否对账回收「文件已消失」的视频 / 书 / 漫画条目（默认开）。
  ///
  /// 关掉只是不做清理，导入行为一个字不变；但库里会继续留着失效条目。
  final bool pruneMissing;
  final LibraryPruneThreshold pruneThreshold;

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
          final _VideoScan scan = await _scanVideos(dir, root, summary);
          if (pruneMissing) await _pruneVideoRoot(dir, root.id, scan, summary);
        case 'book':
          final _BookScan scan = await _scanBooks(dir, root, summary);
          if (pruneMissing) await _pruneBookRoot(dir, root.id, SourceLibraryKind.book, scan, summary);
        case 'manga':
          final _BookScan scan = await _scanManga(dir, root, summary);
          if (pruneMissing) await _pruneBookRoot(dir, root.id, SourceLibraryKind.manga, scan, summary);
        default:
          summary.errors.add('${root.id}: 未支持的 kind "${root.kind}"（只有 video / book / manga）');
      }
    }
    engineLog.logDiagnostic('LibraryScanner', 'scan done: $summary');
    return summary;
  }

  /// 扫描一个视频根，返回**磁盘上现存**的视频文件路径集合（归一）与导入前已在库
  /// 的行 uid（对账的基线），供对账复用。
  Future<_VideoScan> _scanVideos(Directory dir, LibraryRootConfig root, ScanSummary summary) async {
    final SourceLibraryRow source = await _ensureSource(dir, root, SourceLibraryKind.video);
    final List<String> createdPaths = <String>[];
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
    // 下面的循环会往 existingKeys 里追加本轮新行，基线要在这之前单独留一份。
    final Set<String> baselineKeys = Set<String>.of(existingKeys);
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
          sourceId: Value<int?>(source.id),
        ));
        createdPaths.add(file.path);
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
    await _organizeVideoSource(
      source,
      <String>[for (final File file in files) file.path],
      createdPaths,
      summary,
    );
    return _VideoScan(found: found, baselineBookUids: baselineKeys);
  }

  /// 库根 [path] 已登记的本地 `media_sources` 行（按 [kind] + 归一后的绝对路径）；没有返回 null。
  static Future<SourceLibraryRow?> findLocalSource(FushiDatabase db, String path, SourceLibraryKind kind) async {
    final String rootPath = p.normalize(Directory(path).absolute.path);
    for (final SourceLibraryRow row in await db.getMediaSourcesByKind(kind.dbValue)) {
      if (row.transport == 'local' && p.equals(p.normalize(row.rootPath), rootPath)) return row;
    }
    return null;
  }

  /// 库根 → 一行本地 `media_sources`（按 kind + 归一后的绝对路径复用）。标签取库根 id。
  Future<SourceLibraryRow> _ensureSource(Directory dir, LibraryRootConfig root, SourceLibraryKind kind) async {
    final SourceLibraryRow? existing = await findLocalSource(db, dir.path, kind);
    if (existing != null) return existing;
    final String rootPath = p.normalize(dir.absolute.path);
    final int id = await db.insertMediaSource(MediaSourcesCompanion(
      label: Value(root.id),
      mediaKind: Value(kind.dbValue),
      transport: const Value('local'),
      rootPath: Value(rootPath),
      recursive: const Value(true),
      createdAt: Value(DateTime.now().millisecondsSinceEpoch),
    ));
    return (await db.getMediaSourceById(id))!;
  }

  /// 入库之后的整理，与 app `SourceLibraryScanner` 视频分支同序：归组（顺带把存量
  /// 无来源的行回填到本来源）→ NFO 索引 → 记来源扫描结果。花絮（`classifyLocalVideoExtra`）
  /// 在作品识别模式下不进归组，由索引器挂到作品上。
  Future<void> _organizeVideoSource(
    SourceLibraryRow source,
    List<String> videoPaths,
    List<String> createdPaths,
    ScanSummary summary,
  ) async {
    String? error;
    try {
      await VideoFolderGroupCoordinator(database: db, repository: _videos).groupPaths(
        videoPaths: <String>[
          for (final String path in videoPaths)
            if (source.videoGroupingMode == 'folder' || classifyLocalVideoExtra(path) == null) path,
        ],
        createdVideoPaths: createdPaths,
        sourceId: source.id,
        groupingMode: source.videoGroupingMode,
        sourceRoot: source.rootPath,
      );
      if (source.videoGroupingMode != 'folder') {
        await VideoSourceMetadataIndexer(db).index(source);
      }
    } catch (e, stack) {
      error = '$e';
      summary.errors.add('${source.label}: 归组 / NFO 索引失败: $e');
      engineLog.log('LibraryScanner.organize', e, stack);
    }
    await db.updateMediaSourceScanResult(
      id: source.id,
      mediaCount: createdPaths.length,
      lastScannedAt: DateTime.now(),
      lastScanError: error,
    );
  }

  /// 对一个视频根做一次对账（见 [pruneMissingVideoRows]）。
  ///
  /// 护栏 / 刮削租约拦下只记 note，不算错误：扫描因环境暂时无法安全清理，不是失败。
  /// 只在**本轮导入前**就在库里的行上判失效：本轮新导入的行文件必然在，把它们算进
  /// 分母会让整库改名 / 搬家（旧行全失效、新行等量入库）刚好卡在比例阈值上放行。
  Future<void> _pruneVideoRoot(
    Directory dir,
    String rootId,
    _VideoScan scan,
    ScanSummary summary,
  ) async {
    final LibraryPruneReport report = await pruneMissingVideoRows(
      repository: _videos,
      root: dir,
      foundPaths: scan.found,
      baselineBookUids: scan.baselineBookUids,
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
    if (report.unreachable > 0) {
      summary.pruneNotes.add(
        '$rootId: kept ${report.unreachable} missing video row(s) under an '
        'empty or unreadable folder (unmounted disk?)',
      );
    }
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

  /// 对一个书 / 漫画根做一次对账（见引擎 `pruneMissingBookRows`）。护栏同视频根；
  /// 只在本轮导入前就被索引认领的书上判失效。
  Future<void> _pruneBookRoot(
    Directory dir,
    String rootId,
    SourceLibraryKind kind,
    _BookScan scan,
    ScanSummary summary,
  ) async {
    final LibraryPruneReport report = await pruneMissingBookRows(
      db: db,
      sourceId: scan.source.id,
      root: dir,
      kind: kind,
      index: scan.index,
      foundRelPaths: scan.found,
      baselineBookUids: scan.baselineUids,
      threshold: pruneThreshold,
      force: pruneForce,
    );
    final String noun = kind == SourceLibraryKind.manga ? 'manga volume' : 'book';
    if (report.skipped) {
      summary.pruneSkipped++;
      summary.pruneNotes.add('$rootId: ${report.skipReason}');
      engineLog.logDiagnostic('LibraryScanner.prune', '$rootId: skipped (${report.skipReason})');
      return;
    }
    if (kind == SourceLibraryKind.manga) {
      summary.mangaPruned += report.deleted;
    } else {
      summary.booksPruned += report.deleted;
    }
    if (report.unreachable > 0) {
      summary.pruneNotes.add(
        '$rootId: kept ${report.unreachable} missing $noun(s) under an '
        'empty or unreadable folder (unmounted disk?)',
      );
    }
    if (report.missing > 0) {
      engineLog.logDiagnostic('LibraryScanner.prune', '$rootId: removed ${report.deleted} of ${report.missing} stale $noun(s)');
    }
    for (final String e in report.errors) {
      summary.errors.add('$rootId: prune: $e');
      engineLog.logDiagnostic('LibraryScanner.prune', '$rootId: $e');
    }
  }

  /// 书 / 漫画根扫描的公共前半：登记来源、读索引并丢掉指向已不在库的书的条目，
  /// 记下导入前已被认领的书（对账基线）。
  Future<_BookScan> _beginBookScan(Directory dir, LibraryRootConfig root, SourceLibraryKind kind) async {
    final SourceLibraryRow source = await _ensureSource(dir, root, kind);
    final BookSourceIndex index = await BookSourceIndex.load(db, source.id);
    index.retainUids(<String>{
      for (final BookSourceRow r in await loadBookSourceRows(db))
        if (r.uid.isNotEmpty) r.uid,
    });
    return _BookScan(source: source, index: index, found: <String>{}, baselineUids: index.uids);
  }

  /// 书 / 漫画根扫描的公共后半：落索引、记来源扫描结果；认领不上的同名书如实留痕。
  Future<void> _finishBookScan(String rootId, _BookScan scan, int added, int untracked) async {
    await scan.index.save(db);
    await db.updateMediaSourceScanResult(
      id: scan.source.id,
      mediaCount: added,
      lastScannedAt: DateTime.now(),
      lastScanError: null,
    );
    if (untracked > 0) {
      engineLog.logDiagnostic(
        'LibraryScanner.prune',
        '$rootId: $untracked source(s) match a book owned by another library or a '
            'manual import; they are not tracked and never pruned',
      );
    }
  }

  Future<_BookScan> _scanBooks(Directory dir, LibraryRootConfig root, ScanSummary summary) async {
    final _BookScan scan = await _beginBookScan(dir, root, SourceLibraryKind.book);
    final int addedBefore = summary.booksAdded;
    int untracked = 0;
    for (final String path in await listEpubSourceFiles(dir)) {
      final bool tracked = await _importTracked(
        scan,
        dir,
        path,
        summary,
        isManga: false,
        format: BookFormat.epub,
        sourceFileName: p.basename(path),
        import: () => EpubImporter.importFromPath(
          db: db,
          filePath: path,
          fileName: p.basename(path),
          policy: const DuplicatePolicy.skip(),
          sourceId: scan.source.id,
        ),
      );
      if (!tracked) untracked++;
    }
    await _finishBookScan(root.id, scan, summary.booksAdded - addedBefore, untracked);
    return scan;
  }

  /// 漫画根：先逐个导入 `.mokuro` 卷，再把引擎归组出的纯页图卷目录逐个导入
  /// （标题 = 目录名，与 app 源库扫描同口径）。重复卷按标题身份静默跳过；单卷
  /// 失败只记错误，不中断整批。
  ///
  /// cbz / cbr / pdf 本轮不做：压缩包导入器（`MangaArchiveImporter`）还在 app 侧
  /// 且 rar/cb7 依赖外部 7-Zip；等它下沉进引擎再接。
  Future<_BookScan> _scanManga(Directory dir, LibraryRootConfig root, ScanSummary summary) async {
    final _BookScan scan = await _beginBookScan(dir, root, SourceLibraryKind.manga);
    final int addedBefore = summary.mangaAdded;
    int untracked = 0;
    final MangaFolderPlan plan = planMangaFoldersInDirectory(dir);
    for (final String mokuroPath in plan.mokuroPaths) {
      final bool tracked = await _importTracked(
        scan,
        dir,
        mokuroPath,
        summary,
        isManga: true,
        format: BookFormat.manga,
        import: () => MangaImporter.importFromMokuroPath(
          db: db,
          mokuroPath: mokuroPath,
          policy: const DuplicatePolicy.skip(),
          sourceId: scan.source.id,
        ),
      );
      if (!tracked) untracked++;
    }
    for (final String folder in plan.imageFolders) {
      final bool tracked = await _importTracked(
        scan,
        dir,
        folder,
        summary,
        isManga: true,
        format: BookFormat.manga,
        import: () => MangaImporter.importFromImageFolder(
          db: db,
          imageDirPath: folder,
          title: p.basename(folder),
          policy: const DuplicatePolicy.skip(),
          sourceId: scan.source.id,
        ),
      );
      if (!tracked) untracked++;
    }
    await _finishBookScan(root.id, scan, summary.mangaAdded - addedBefore, untracked);
    return scan;
  }

  /// 导入一个书 / 漫画源并登记进来源索引。返回 false 表示这个源撞上了一本
  /// **认领不了**的同名书（别的库根 / 手动导入的）：它不进索引，也就永远不会被对账删。
  ///
  /// 索引里已有该源且书还在库 → 不再导入（此前每轮都重新解压整本再判重复）。
  /// 导入被判重复 → 交给引擎 `adoptExistingBookForSource` 按保守判据认领存量行
  /// （旧版扫描进来、没记来源的书在这里回填）。单卷失败只记错误，不中断整批。
  Future<bool> _importTracked(
    _BookScan scan,
    Directory dir,
    String sourcePath,
    ScanSummary summary, {
    required bool isManga,
    required BookFormat format,
    String? sourceFileName,
    required Future<String> Function() import,
  }) async {
    final String rel = bookSourceRelPath(dir.path, sourcePath);
    scan.found.add(rel);
    if (scan.index.uidOf(rel) != null) {
      isManga ? summary.mangaSkipped++ : summary.booksSkipped++;
      return true;
    }
    try {
      final String bookKey = await import();
      final String? uid = await bookUidForKey(db, bookKey);
      if (uid != null) scan.index.put(rel, uid);
      isManga ? summary.mangaAdded++ : summary.booksAdded++;
    } on DuplicateImportCancelledException catch (dup) {
      isManga ? summary.mangaSkipped++ : summary.booksSkipped++;
      final String? uid = await adoptExistingBookForSource(
        db: db,
        sourceId: scan.source.id,
        proposedTitle: dup.title,
        format: format,
        sourceFileName: sourceFileName,
      );
      if (uid == null) return false;
      scan.index.put(rel, uid);
    } catch (err, stack) {
      summary.errors.add('$sourcePath: $err');
      engineLog.log(isManga ? 'LibraryScanner.manga' : 'LibraryScanner.book', err, stack);
    }
    return true;
  }

  /// 视频根收录的文件：视频容器 + 纯音频（无画面的视频，见
  /// [kVideoLibraryMediaExtensions]）。与对账枚举 `enumerateLocalVideoPaths`
  /// 同一张表，否则收进来的音频会在下一次对账被当成「磁盘上已不存在」修剪掉。
  static bool _isVideo(String path) {
    final String ext = p.extension(path).toLowerCase();
    return kVideoLibraryMediaExtensions.contains(ext);
  }
}
