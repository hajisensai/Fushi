import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/epub/book_title_conflict.dart';
import 'package:hibiki/src/epub/epub_storage.dart';
import 'package:hibiki/src/pdf/pdf_engine.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki/src/utils/misc/hibiki_time_format.dart';

/// PDF 阅读器（Phase 1）的导入器：把一份 PDF 作为「第二种书」落进 `EpubBooks`
/// 表（`format='pdf'`），复用整套书架 / 进度 / 删除管线，而非另建平行表。
///
/// 与 [EpubImporter] 的差别：PDF 不解压、无章节 HTML。落库形态：
/// - `epubPath` = 拷进书目录的 PDF 文件名（`document.pdf`）。
/// - `extractDir` = 该书目录（`<hoshi_books>/<bookKey>/`），阅读器用
///   `p.join(extractDir, epubPath)` 还原 PDF 绝对路径。
/// - `coverPath` = pdfrx 栅格化首页得到的 `cover.png`（书架封面复用同一解析）。
/// - `chapterCount` = PDF 总页数；`chaptersJson='[]'`（PDF 无章字数，页码进度是
///   Phase 3 的事）。
///
/// 删除零改动复用 [HibikiDatabase.deleteEpubBook]（按 bookKey 级联）+
/// [ReaderHibikiSource.deleteBook] 的磁盘清理（`EpubStorage.deleteBookDir`）。
class PdfImporter {
  PdfImporter._();

  /// 书目录内固定的 PDF 文件名。阅读器按 `extractDir/epubPath` 还原绝对路径，故此名
  /// 与 `epubPath` 列必须一致。
  static const String kPdfFileName = 'document.pdf';

  /// 书目录内固定的封面文件名。
  static const String kCoverFileName = 'cover.png';

  /// 从磁盘路径导入一份 PDF。成功返回 bookKey（= 净化后的标题，`EpubBooks` 主键）；
  /// 用户在同名弹窗取消时抛 [DuplicateImportCancelledException]（由调用方按取消处理）；
  /// 其它失败抛异常并回滚已插入的行与已建的书目录。
  ///
  /// [title] 由导入对话框传入（用户可编辑的标题输入框值）——PDF 元数据里的标题不可靠，
  /// 以用户输入为准，与文本转 EPUB 的口径一致。
  static Future<String> importFromPath({
    required HibikiDatabase db,
    required String filePath,
    required String fileName,
    required String title,
    DuplicatePolicy policy = const DuplicatePolicy.suffix(),
    int? sourceId,
  }) async {
    await PdfEngine.ensureInitialized();

    // 先探测页数并栅格化首页当封面（打开一次 PDF 文档）。渲染在 bookKey 解析前完成，
    // 失败即整体失败、不落任何行/目录。
    final int pageCount;
    Uint8List? coverPng;
    final PdfDocument document = await PdfDocument.openFile(filePath);
    try {
      pageCount = document.pages.length;
      if (pageCount <= 0) {
        throw StateError('PDF 无任何页：$filePath');
      }
      coverPng = await _renderCoverPng(document.pages.first);
    } finally {
      await document.dispose();
    }

    // 解析标题冲突 → bookKey（与 EpubImporter 同口径：净化标题即主键，保证本地唯一）。
    final List<EpubBookRow> existingBooks = await db.getAllEpubBooks();
    final String storedTitle = await resolveDuplicateTitle(
      existingTitles: existingBooks.map((EpubBookRow b) => b.title).toList(),
      proposedTitle: title,
      policy: policy,
    );
    final String bookKey = sanitizeTtuFilename(storedTitle);

    final String bookDir = await EpubStorage.bookDirectory(bookKey);
    String? insertedKey;
    try {
      // 把 PDF 拷进书目录（原文件在缓存/外部目录，阅读器需稳定内部副本）。
      await File(filePath).copy(p.join(bookDir, kPdfFileName));

      String? coverRel;
      if (coverPng != null) {
        await File(p.join(bookDir, kCoverFileName))
            .writeAsBytes(coverPng, flush: true);
        coverRel = kCoverFileName;
      }

      final int importedAtMs = DateTime.now().millisecondsSinceEpoch;
      insertedKey = await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: bookKey,
          title: storedTitle,
          coverPath: coverRel != null ? Value(coverRel) : const Value.absent(),
          epubPath: kPdfFileName,
          extractDir: bookDir,
          chapterCount: pageCount,
          chaptersJson: '[]',
          importedAt: importedAtMs,
          format: Value(BookFormat.pdf.dbValue),
          sourceId: sourceId != null ? Value(sourceId) : const Value.absent(),
        ),
      );

      // 与 EpubImporter 一致：写一条「added」活动事件喂首页时间轴。best-effort。
      try {
        await db.addActivityEvent(
          eventType: kActivityAdded,
          mediaType: kActivityMediaBook,
          title: storedTitle,
          mediaKey: bookKey,
          dateKey: HibikiTimeFormat.dayKey(
              DateTime.fromMillisecondsSinceEpoch(importedAtMs)),
          timestampMs: importedAtMs,
        );
      } catch (e) {
        ErrorLogService.instance
            .log('PdfImporter.addActivityEvent', e, StackTrace.current);
      }

      return insertedKey;
    } catch (e) {
      // 回滚：删掉可能已插入的行 + 已建的书目录，避免半成品残留。
      if (insertedKey != null) {
        try {
          await db.deleteEpubBook(insertedKey);
        } catch (rollbackError, stack) {
          ErrorLogService.instance
              .log('PdfImporter.rollbackDelete', rollbackError, stack);
        }
      }
      try {
        final Directory dir = Directory(bookDir);
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } catch (cleanupError, stack) {
        ErrorLogService.instance
            .log('PdfImporter.rollbackDir', cleanupError, stack);
      }
      rethrow;
    }
  }

  /// 把 PDF 首页栅格化成封面 PNG 字节（失败返回 null，不阻断导入——书仍可无封面入架）。
  /// 目标宽度约 600px 以保证书架封面清晰；高度按页面纵横比等比。
  static Future<Uint8List?> _renderCoverPng(PdfPage page) async {
    try {
      const double targetWidth = 600;
      final double scale = page.width > 0 ? targetWidth / page.width : 1.0;
      final double fullWidth = page.width * scale;
      final double fullHeight = page.height * scale;
      final PdfImage? rendered = await page.render(
        fullWidth: fullWidth,
        fullHeight: fullHeight,
        backgroundColor: 0xFFFFFFFF,
      );
      if (rendered == null) return null;
      try {
        return await _bgraToPng(
          rendered.pixels,
          rendered.width,
          rendered.height,
        );
      } finally {
        rendered.dispose();
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('PdfImporter.renderCover', e, stack);
      return null;
    }
  }

  /// 把 PDFium 输出的 BGRA8888 位图编码成 PNG 字节（纯 CPU codec，无 GPU 回读，
  /// 与 Phase 0 spike 同路径，离屏可靠）。
  static Future<Uint8List?> _bgraToPng(
    Uint8List bgra,
    int width,
    int height,
  ) async {
    final ui.ImmutableBuffer buffer =
        await ui.ImmutableBuffer.fromUint8List(bgra);
    final ui.ImageDescriptor descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: width,
      height: height,
      pixelFormat: ui.PixelFormat.bgra8888,
    );
    final ui.Codec codec = await descriptor.instantiateCodec();
    final ui.FrameInfo frame = await codec.getNextFrame();
    final ui.Image image = frame.image;
    try {
      final ByteData? png =
          await image.toByteData(format: ui.ImageByteFormat.png);
      return png?.buffer.asUint8List();
    } finally {
      image.dispose();
      codec.dispose();
    }
  }
}
