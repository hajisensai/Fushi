import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/epub/pdf_book_layout.dart';
import 'package:fushi/src/pdf/pdf_engine.dart';
import 'package:fushi_engine/media/cover_file_writer.dart'
    show CoverImageInvalidException, writeCoverBytesAtomically;
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/utils/misc/fushi_time_format.dart';

/// PDF 阅读器（Phase 1）的导入器：把一份 PDF 作为「第二种书」落进 `EpubBooks`
/// 表（`format='pdf'`），复用整套书架 / 进度 / 删除管线，而非另建平行表。
///
/// 与 [EpubImporter] 的差别：PDF 不解压、无章节 HTML。落库形态：
/// - `epubPath` = 拷进书目录的 PDF 文件名（`document.pdf`）。
/// - `extractDir` = 该书目录（`<fushi_books>/<bookKey>/`），阅读器用
///   `p.join(extractDir, epubPath)` 还原 PDF 绝对路径。
/// - `coverPath` = pdfrx 栅格化首页得到的 `cover.png`（书架封面复用同一解析）。
/// - `chapterCount` = PDF 总页数；`chaptersJson='[]'`（PDF 无章字数，页码进度是
///   Phase 3 的事）。
///
/// 删除零改动复用 [FushiDatabase.deleteEpubBook]（按 bookKey 级联）+
/// [ReaderFushiSource.deleteBook] 的磁盘清理（`EpubStorage.deleteBookDir`）。
class PdfImporter {
  PdfImporter._();

  /// 书目录内固定的 PDF 文件名。阅读器按 `extractDir/epubPath` 还原绝对路径，故此名
  /// 与 `epubPath` 列必须一致。
  static const String kPdfFileName = PdfBookLayout.pdfFileName;

  /// 书目录内固定的封面文件名。
  static const String kCoverFileName = 'cover.png';

  /// 从磁盘路径导入一份 PDF。成功返回 bookKey（= 净化后的标题，`EpubBooks` 主键）；
  /// 用户在同名弹窗取消时抛 [DuplicateImportCancelledException]（由调用方按取消处理）；
  /// 其它失败抛异常并回滚已插入的行与已建的书目录。
  ///
  /// [title] 由导入对话框传入（用户可编辑的标题输入框值）——PDF 元数据里的标题不可靠，
  /// 以用户输入为准，与文本转 EPUB 的口径一致。
  static Future<String> importFromPath({
    required FushiDatabase db,
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
    final List<EpubBookMeta> existingBooks = await db.getEpubBookMetas();
    final String storedTitle = await resolveDuplicateTitle(
      existingTitles: existingBooks.map((EpubBookMeta b) => b.title).toList(),
      proposedTitle: title,
      policy: policy,
    );
    final String bookKey = sanitizeTtuFilename(storedTitle);

    final String bookDir = await EpubStorage.bookDirectory(bookKey);
    String? insertedKey;
    try {
      // 把 PDF 拷进书目录（原文件在缓存/外部目录，阅读器需稳定内部副本）。
      await File(filePath).copy(p.join(bookDir, kPdfFileName));

      // BUG-2496：封面走收口（校验完整可解码 + 原子写 + 驱逐）。pdfrx 渲染出的字节
      // 理应是完整 PNG，但栅格化失败/半截时不能让整本 PDF 导入失败——记诊断、
      // coverPath 留空，书架回落占位图。
      String? coverRel;
      if (coverPng != null) {
        try {
          await writeCoverBytesAtomically(
            bytes: coverPng,
            destPath: p.join(bookDir, kCoverFileName),
          );
          coverRel = kCoverFileName;
        } on CoverImageInvalidException catch (e) {
          ErrorLogService.instance.logDiagnostic('PdfImporter.cover', e);
        }
      }

      final int importedAtMs = DateTime.now().millisecondsSinceEpoch;
      insertedKey = await db.insertEpubBook(
        bookRowFor(
          bookKey: bookKey,
          title: storedTitle,
          coverRel: coverRel,
          bookDir: bookDir,
          pageCount: pageCount,
          importedAt: importedAtMs,
          sourceId: sourceId,
        ),
      );

      // 与 EpubImporter 一致：写一条「added」活动事件喂首页时间轴。best-effort。
      try {
        await db.addActivityEvent(
          eventType: kActivityAdded,
          mediaType: kActivityMediaBook,
          title: storedTitle,
          mediaKey: bookKey,
          dateKey: FushiTimeFormat.dayKey(
            DateTime.fromMillisecondsSinceEpoch(importedAtMs),
          ),
          timestampMs: importedAtMs,
        );
      } catch (e) {
        ErrorLogService.instance.log(
          'PdfImporter.addActivityEvent',
          e,
          StackTrace.current,
        );
      }

      return insertedKey;
    } catch (e) {
      // 回滚：删掉可能已插入的行 + 已建的书目录，避免半成品残留。
      if (insertedKey != null) {
        try {
          await db.deleteEpubBook(insertedKey);
        } catch (rollbackError, stack) {
          ErrorLogService.instance.log(
            'PdfImporter.rollbackDelete',
            rollbackError,
            stack,
          );
        }
      }
      try {
        final Directory dir = Directory(bookDir);
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } catch (cleanupError, stack) {
        ErrorLogService.instance.log(
          'PdfImporter.rollbackDir',
          cleanupError,
          stack,
        );
      }
      rethrow;
    }
  }

  /// PDF 书目录 → `EpubBooks` 行：导入（[importFromPath]）与「孤儿书目录重新登记」
  /// （[registerExistingBookDir]，BUG-4701）共用的唯一行构造口径。
  static EpubBooksCompanion bookRowFor({
    required String bookKey,
    required String title,
    required String? coverRel,
    required String bookDir,
    required int pageCount,
    required int importedAt,
    int? sourceId,
  }) {
    return EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: title,
      coverPath: coverRel != null ? Value(coverRel) : const Value.absent(),
      epubPath: kPdfFileName,
      extractDir: bookDir,
      chapterCount: pageCount,
      chaptersJson: '[]',
      importedAt: importedAt,
      format: Value(BookFormat.pdf.dbValue),
      sourceId: sourceId != null ? Value(sourceId) : const Value.absent(),
    );
  }

  /// 把盘上已有、但没有书库行的 PDF 书目录 [bookDir]（`document.pdf` [+ `cover.png`]）
  /// 重新登记成书（BUG-4701）。[bookKey] 由调用方给定（= 目录名），不重新派生。
  /// 页数重新从 PDF 读；封面沿用目录里已有的 `cover.png`，没有就不补渲染（书架
  /// 回落占位图，与导入时封面渲染失败同态）。
  static Future<String> registerExistingBookDir({
    required FushiDatabase db,
    required String bookKey,
    required String title,
    required String bookDir,
  }) async {
    await PdfEngine.ensureInitialized();
    final PdfDocument document = await PdfDocument.openFile(
      p.join(bookDir, kPdfFileName),
    );
    final int pageCount;
    try {
      pageCount = document.pages.length;
    } finally {
      await document.dispose();
    }
    if (pageCount <= 0) {
      throw StateError('PDF 无任何页：$bookDir');
    }
    return db.insertEpubBook(
      bookRowFor(
        bookKey: bookKey,
        title: title,
        coverRel: File(p.join(bookDir, kCoverFileName)).existsSync()
            ? kCoverFileName
            : null,
        bookDir: bookDir,
        pageCount: pageCount,
        importedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// 把 PDF 首页栅格化成封面 PNG 字节（失败返回 null，不阻断导入——书仍可无封面入架）。
  /// 目标宽度约 600px 以保证书架封面清晰；高度按页面纵横比等比。
  ///
  /// 栅格化与 PNG 编码本体在 [PdfEngine]：「PDF → 漫画」转化要逐页导出同款页图，
  /// 两处各写一份的话背景色/缩放/dispose 时机随时能漂。
  static Future<Uint8List?> _renderCoverPng(PdfPage page) =>
      PdfEngine.renderPagePng(page, targetWidth: 600);
}
