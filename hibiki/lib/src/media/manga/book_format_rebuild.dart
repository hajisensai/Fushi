/// 「书 ↔ 漫画」转化的**产物重建 + 落库**（`book_format_convert.dart` 只做判定）。
///
/// ## 一句话
///
/// 转化不是翻一个字段，是**让目标格式的磁盘产物存在，然后把行指过去**。身份
/// （`EpubBooks.bookKey` = 主键 = 合集/标签/进度/统计/Profile 的 entryKey）与书目录
/// （`extractDir`，三种格式共用同一个）全程不动，所以转化天然零悬挂引用。
///
/// ## 「源产物」是什么（这是本文件最容易踩错的一条）
///
/// 三种 format 的书侧源产物形态不同，且**都不是 `extractDir/epubPath`**：
/// - `format='epub'`：源产物 = **解压书目录本身**。本仓的 EPUB 导入即解压、
///   从不在书目录里留一份独立 `.epub`；`epubPath` 只是导入时的原始文件名，
///   `p.join(extractDir, epubPath)` **永远指不到真实文件**（BUG-088 已就此坏过一次：
///   同步的 `File(book.epubPath).existsSync()` 守卫因此静默跳过了每一次上传）。
///   照着「原始 `.epub` 仍在书目录里」去探测，每一本 EPUB 都会被判成
///   [BookConvertBlocker.sourceMissing]，转化对文字书/图片书**全线不可用**。
/// - `format='pdf'`：源产物 = `extractDir/document.pdf`（导入时真的拷进去了）。
/// - `format='manga'`：`epubPath` = `manga.json`，是漫画侧产物；书侧源产物要么是
///   仍在的 `document.pdf`，要么是仍在的 EPUB 解压树，要么压根没有过
///   （`.mokuro`/裸图片目录导入的漫画）。
///
/// ## 往返不掉东西
///
/// 转回书**不删**漫画产物（`manga.json` + `images/`），转成漫画时若 `manga.json`
/// 仍然完好就直接复用。于是「书 → 漫画 → 书 → 漫画」的往返不会把整卷 OCR 结果
/// 冲掉——OCR 是用户花小时级时间跑出来的，重建一次就没了才是真的丢数据。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/epub/epub_book.dart';
import 'package:fushi/src/epub/epub_importer.dart';
import 'package:fushi/src/epub/epub_parser.dart';
import 'package:fushi/src/media/manga/book_format_convert.dart';
import 'package:fushi/src/media/manga/import/manga_archive_importer.dart';
import 'package:fushi/src/media/manga/manga_importer.dart';
import 'package:fushi/src/media/manga/manga_storage.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';
import 'package:fushi/src/pdf/pdf_engine.dart';
import 'package:fushi/src/pdf/pdf_importer.dart';
import 'package:fushi/src/sync/ttu_filename.dart';

/// PDF 逐页导出页图时的目标宽度（px）。比封面的 600 大得多：页图是**要拿去 OCR 再
/// 查词**的，600px 的扫描页在识别端就是一团糊。
const double kPdfPageRasterWidth = 1600;

/// 把 [pdfPath] 的每一页栅格化成 PNG 落进 [staging]，返回页数。
///
/// 注入点：PDFium 是平台原生库，`flutter test` 里拉不起来（native assets 不布置、
/// worker isolate 直接 open 失败）。把这一处原生依赖收成可替换函数，转化的编排、
/// 产物布局与落库就都能被真单测覆盖，而不是只能靠真机跑一遍。
typedef PdfPageStager = Future<int> Function(
  String pdfPath,
  Directory staging,
  void Function(int done, int total)? onProgress,
);

/// 读 [pdfPath] 的页数（「漫画 → PDF」转回时算 `chapterCount`）。同上，可注入。
typedef PdfPageCounter = Future<int> Function(String pdfPath);

/// 一本书的源产物探测结果：喂给 `book_format_convert.dart` 纯判定的**事实**。
class BookConvertProbe {
  const BookConvertProbe({required this.probe, required this.sourcePath});

  /// 判定所需的磁盘事实。
  final BookSourceProbe probe;

  /// 转成漫画时要读的源产物绝对路径（EPUB 行 = 解压书目录；PDF 行 = 那个 PDF）。
  final String sourcePath;
}

/// 转化引擎。静态入口 + 两个可注入的原生依赖。
abstract final class BookFormatRebuild {
  /// 单测注入点（见 [PdfPageStager]）。null = 用真实的 PDFium 实现。
  @visibleForTesting
  static PdfPageStager? debugPdfPageStager;

  /// 单测注入点（见 [PdfPageCounter]）。null = 用真实的 PDFium 实现。
  @visibleForTesting
  static PdfPageCounter? debugPdfPageCounter;

  /// 探测 [row] 的书目录，产出判定所需的事实。
  ///
  /// 纯 IO，不做任何判断——「能不能转」全部交给 `book_format_convert.dart` 的纯
  /// 函数，这样判据只有一份、且能不碰磁盘地单测。
  static BookConvertProbe probeSource(EpubBookRow row) {
    final BookFormat format = BookFormat.parseOrEpub(row.format);
    final String extractDir = row.extractDir;
    switch (format) {
      case BookFormat.pdf:
        final String pdf = p.join(extractDir, row.epubPath);
        return BookConvertProbe(
          probe: BookSourceProbe(
            sourceExists: File(pdf).existsSync(),
            // PDF 恒可栅格化成页图，这一位对 PDF 无意义。
            sourceIsImageArchive: false,
          ),
          sourcePath: pdf,
        );
      case BookFormat.epub:
        final EpubBook? book = tryParseExtractedBook(extractDir);
        return BookConvertProbe(
          probe: BookSourceProbe(
            sourceExists: book != null,
            sourceIsImageArchive:
                book != null && MangaArchiveImporter.isPureImageEpub(book),
          ),
          sourcePath: extractDir,
        );
      case BookFormat.manga:
        return BookConvertProbe(
          probe: BookSourceProbe(
            sourceExists: File(p.join(extractDir, row.epubPath)).existsSync(),
            sourceIsImageArchive: false,
            recoverableOriginalPath: recoverableBookSource(extractDir),
          ),
          sourcePath: p.join(extractDir, row.epubPath),
        );
    }
  }

  /// 磁盘探测 + 纯判定的合成：这本书能不能转成 [target]？
  ///
  /// UI 在**点击时**调它（而不是在建菜单时）：探测要解析 OPF，放进 build 会把
  /// 书架每次重绘都拖进磁盘 IO；而且被挡住时给一句具体原因，比灰掉一个按钮有用。
  static BookConvertVerdict resolveVerdict({
    required EpubBookRow row,
    required BookFormatTarget target,
  }) {
    final BookConvertProbe probed = probeSource(row);
    final BookFormat format = BookFormat.parseOrEpub(row.format);
    switch (target) {
      case BookFormatTarget.manga:
        return verdictToManga(
          format: format,
          sourceAbsolutePath: probed.sourcePath,
          probe: probed.probe,
        );
      case BookFormatTarget.book:
        return verdictToBook(format: format, probe: probed.probe);
    }
  }

  /// 执行转化：重建目标格式的磁盘产物，再在**单事务**里把行指过去。
  ///
  /// 判定不通过时抛 [BookConvertBlockedException]（调用方据 [BookConvertBlocker]
  /// 给出具体说明），重建失败时抛 [MangaImportException] 或底层 IO 异常。
  /// [onProgress] 回报 `(done, total)`：转漫画时是页，转回书时不回报（一次解析）。
  ///
  /// **失败不改行**：产物重建整段跑完才写库。半途失败只可能在书目录里留下多余的
  /// 页图，行仍指向原格式，书照旧能打开——这比「行已改、产物没建完」安全得多。
  static Future<void> convert({
    required HibikiDatabase db,
    required EpubBookRow row,
    required BookFormatTarget target,
    void Function(int done, int total)? onProgress,
  }) async {
    final BookConvertVerdict verdict = resolveVerdict(row: row, target: target);
    final BookConvertBlocker? blocker = verdict.blocker;
    if (blocker != null) throw BookConvertBlockedException(blocker);
    final String source = verdict.sourcePath!;
    switch (target) {
      case BookFormatTarget.manga:
        await _rebuildToManga(
          db: db,
          row: row,
          sourcePath: source,
          sourceFormat: BookFormat.parseOrEpub(row.format),
          onProgress: onProgress,
        );
      case BookFormatTarget.book:
        await _rebuildToBook(db: db, row: row, sourcePath: source);
    }
  }

  // ── 转成漫画 ────────────────────────────────────────────────────────

  static Future<void> _rebuildToManga({
    required HibikiDatabase db,
    required EpubBookRow row,
    required String sourcePath,
    required BookFormat sourceFormat,
    void Function(int done, int total)? onProgress,
  }) async {
    final String bookDir = row.extractDir;
    final ({int pageCount, String coverRel})? reused =
        _reusableMangaArtifacts(bookDir);
    final ({int pageCount, String coverRel}) artifacts = reused ??
        await _buildMangaArtifacts(
          bookDir: bookDir,
          sourcePath: sourcePath,
          sourceFormat: sourceFormat,
          onProgress: onProgress,
        );

    await db.transaction(() async {
      // 单条 UPDATE 本就原子；包事务是为了让「转化落库是一个不可分单位」这条不变量
      // 在有人往里加第二条语句时**继续**成立，而不是那时才发现它从来没被保证过。
      await db.updateEpubBookFormat(
        row.bookKey,
        format: BookFormat.manga,
        epubPath: MangaStorage.kMangaJsonFileName,
        chapterCount: artifacts.pageCount,
        chaptersJson: '[]',
        coverPath: artifacts.coverRel,
        // 无条件清成 null = 跟随页图长宽比自动判定。复用旧产物时也照清：上一轮的
        // 手动覆盖未必还配得上这一批页图。
        mangaReadingMode: null,
      );
    });
  }

  /// 书目录里已有的漫画产物还能不能直接用：`manga.json` 解析得通、有页、且它引用的
  /// 每一张页图都还在。能用就返回页数与封面相对路径，否则 null（要重建）。
  static ({int pageCount, String coverRel})? _reusableMangaArtifacts(
    String bookDir,
  ) {
    final File json = File(p.join(bookDir, MangaStorage.kMangaJsonFileName));
    if (!json.existsSync()) return null;
    final MokuroPayload payload;
    try {
      payload = parseMangaJson(json.readAsStringSync());
    } catch (_) {
      return null;
    }
    if (payload.images.isEmpty) return null;
    for (final MokuroImage image in payload.images) {
      if (!MangaStorage.destFile(bookDir, image.url).existsSync()) return null;
    }
    return (
      pageCount: payload.images.length,
      coverRel: payload.images.first.url,
    );
  }

  static Future<({int pageCount, String coverRel})> _buildMangaArtifacts({
    required String bookDir,
    required String sourcePath,
    required BookFormat sourceFormat,
    void Function(int done, int total)? onProgress,
  }) async {
    final Directory staging =
        await Directory.systemTemp.createTemp('hibiki_book_convert_');
    try {
      switch (sourceFormat) {
        case BookFormat.pdf:
          final PdfPageStager stager = debugPdfPageStager ?? _rasterizePdfPages;
          await stager(sourcePath, staging, onProgress);
        case BookFormat.epub:
          // 解压树就是页图来源；沿 spine 顺序铺成 `page_%06d.<ext>`，与压缩包导入
          // 走的是同一个函数（页序必须同口径）。
          final EpubBook? book = tryParseExtractedBook(sourcePath);
          if (book == null) {
            throw const MangaImportException(
              'Extracted EPUB could not be parsed',
            );
          }
          await MangaArchiveImporter.copyEpubPages(book, staging);
        case BookFormat.manga:
          throw const MangaImportException('Already a manga');
      }

      final MokuroPayload payload =
          await MangaImporter.payloadFromImageFolder(staging);
      final List<String> destRels = MangaImporter.planMangaDestRels(
        srcDir: staging,
        payload: payload,
      );
      _refuseIfWouldClobberBookFiles(bookDir: bookDir, destRels: destRels);
      // `return await`（不是 `return`）：在 async 函数里裸 `return future` 会让
      // finally 在 future 完成**之前**就跑，暂存目录被删在拷图中途，第二页起
      // PathNotFoundException。
      return await MangaImporter.copyMangaArtifacts(
        srcDir: staging,
        payload: payload,
        destRels: destRels,
        bookDir: bookDir,
        onProgress: onProgress,
      );
    } finally {
      if (staging.existsSync()) {
        await staging.delete(recursive: true);
      }
    }
  }

  /// 漫画产物落在 `<bookDir>/images/`，而 EPUB 的解压树也住在同一个书目录里。若某本
  /// EPUB 恰好自带顶层 `images/`，铺页图就会**覆盖掉书自己的资源**——转回书时那本书
  /// 少了几张图，且没有任何报错。
  ///
  /// 判据只有一条：目标路径已存在，而书目录里**没有** `manga.json`。没有 manga.json
  /// 就说明 `images/` 不是我们铺的，那是书自己的东西，宁可硬失败也不覆盖。反过来
  /// manga.json 在场时（重建 / 往返）覆盖的是我们自己的上一批产物，本来就该覆盖。
  static void _refuseIfWouldClobberBookFiles({
    required String bookDir,
    required List<String> destRels,
  }) {
    if (File(p.join(bookDir, MangaStorage.kMangaJsonFileName)).existsSync()) {
      return;
    }
    for (final String destRel in destRels) {
      final File dest = MangaStorage.destFile(bookDir, destRel);
      if (dest.existsSync()) {
        throw MangaImportException(
          'Refusing to overwrite an existing book file: $destRel',
        );
      }
    }
  }

  static Future<int> _rasterizePdfPages(
    String pdfPath,
    Directory staging,
    void Function(int done, int total)? onProgress,
  ) async {
    await PdfEngine.ensureInitialized();
    final PdfDocument document = await PdfDocument.openFile(pdfPath);
    try {
      final int total = document.pages.length;
      if (total <= 0) {
        throw const MangaImportException('PDF has no pages');
      }
      for (int i = 0; i < total; i++) {
        final Uint8List? png = await PdfEngine.renderPagePng(
          document.pages[i],
          targetWidth: kPdfPageRasterWidth,
        );
        if (png == null) {
          throw MangaImportException('Could not rasterise PDF page ${i + 1}');
        }
        final String name = 'page_${i.toString().padLeft(6, '0')}.png';
        await File(p.join(staging.path, name)).writeAsBytes(png, flush: true);
        onProgress?.call(i + 1, total);
      }
      return total;
    } finally {
      await document.dispose();
    }
  }

  // ── 转回书 ──────────────────────────────────────────────────────────

  static Future<void> _rebuildToBook({
    required HibikiDatabase db,
    required EpubBookRow row,
    required String sourcePath,
  }) async {
    // [recoverableBookSource] 只会回两种东西：`document.pdf` 这个**文件**，或仍解析
    // 得通的 EPUB **解压目录**。所以「是不是文件」就是「转回 PDF 还是转回 EPUB」，
    // 不需要再看扩展名（扩展名判据会在无扩展名的目录上悄悄退化）。
    final bool isPdf = FileSystemEntity.isFileSync(sourcePath);
    final BookFormat target = isPdf ? BookFormat.pdf : BookFormat.epub;

    final int chapterCount;
    final String chaptersJson;
    final String? coverPath;
    final String epubPath;
    if (isPdf) {
      final PdfPageCounter counter = debugPdfPageCounter ?? _countPdfPages;
      chapterCount = await counter(sourcePath);
      // PDF 无章字数，进度按页（与 PdfImporter 落库口径一致）。
      chaptersJson = '[]';
      epubPath = p.basename(sourcePath);
      final File cover =
          File(p.join(row.extractDir, PdfImporter.kCoverFileName));
      coverPath = cover.existsSync() ? PdfImporter.kCoverFileName : null;
    } else {
      final ({
        int chapterCount,
        String chaptersJson,
        String? coverPath
      }) parsed = await EpubImporter.reparseExtractedBook(sourcePath);
      chapterCount = parsed.chapterCount;
      chaptersJson = parsed.chaptersJson;
      coverPath = parsed.coverPath;
      // 转成漫画时 `epubPath` 被写成 `manga.json`，原始文件名无处可存也无处可用
      // （EPUB 行的 epubPath 从不解析成真实文件）。这里合成的是同步侧
      // (`sync_manager._exportContentIfMissing`) 打包上传时用的同一个名字，
      // 全仓只有这一种「这本书的 epub 文件名」口径。
      epubPath = '${sanitizeTtuFilename(row.title)}.epub';
    }

    await db.transaction(() async {
      await db.updateEpubBookFormat(
        row.bookKey,
        format: target,
        epubPath: epubPath,
        chapterCount: chapterCount,
        chaptersJson: chaptersJson,
        // null = 保持原封面不变。转回书时若算不出封面（EPUB 无 cover-image、
        // PDF 的 cover.png 被删），保留漫画首页当封面也比把书架变成空白格好。
        coverPath: coverPath,
        // 表约定：非漫画行恒 null。
        mangaReadingMode: null,
      );
    });
  }

  static Future<int> _countPdfPages(String pdfPath) async {
    await PdfEngine.ensureInitialized();
    final PdfDocument document = await PdfDocument.openFile(pdfPath);
    try {
      return document.pages.length;
    } finally {
      await document.dispose();
    }
  }

  // ── 共享探测原语 ────────────────────────────────────────────────────

  /// 解析一个**可能是** EPUB 解压树的目录；不是（缺 `META-INF/container.xml`、
  /// OPF 坏了、spine 空）就返回 null。
  static EpubBook? tryParseExtractedBook(String extractDir) {
    if (!Directory(extractDir).existsSync()) return null;
    try {
      return EpubParser.parseFromExtracted(extractDir);
    } catch (_) {
      return null;
    }
  }

  /// 书目录里还能不能还原出**书侧**源产物：优先 `document.pdf`（PDF 导入拷进来的
  /// 那份），否则看解压树是不是仍解析得通。都没有 → null（`.mokuro`/裸图片目录
  /// 导入的漫画就是这一类，转回书对它没有意义）。
  static String? recoverableBookSource(String extractDir) {
    final String pdf = p.join(extractDir, PdfImporter.kPdfFileName);
    if (File(pdf).existsSync()) return pdf;
    if (tryParseExtractedBook(extractDir) != null) return extractDir;
    return null;
  }
}

/// 判定不通过时抛出，带上具体的 [blocker] 供调用方翻译成一句给用户看的原因。
class BookConvertBlockedException implements Exception {
  const BookConvertBlockedException(this.blocker);

  final BookConvertBlocker blocker;

  @override
  String toString() => 'BookConvertBlockedException: $blocker';
}
