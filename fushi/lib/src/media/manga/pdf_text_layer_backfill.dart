import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show Rect, Size;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import 'package:fushi/src/media/manga/manga_json_writeback.dart';
import 'package:fushi/src/pdf/pdf_engine.dart';
import 'package:fushi/src/pdf/pdf_importer.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/media/manga/manga_pdf_text_layer.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 读 [pdfPath] 每一页的文字层，按 [pageSizes]（对应页图的像素尺寸）换算成页图坐标。
///
/// 返回的外层列表与 PDF 页序一致（长度 = PDF 页数，可能与 [pageSizes] 不等，由
/// [applyPdfTextLayer] 判对齐）。可注入：PDFium 在 `flutter test` 里拉不起来。
typedef PdfTextLayerGlyphLoader =
    Future<List<List<PdfTextLayerGlyph>>> Function(
      String pdfPath,
      List<MokuroSize> pageSizes,
    );

/// 由 PDF 转来的漫画卷：把 PDF 自带文字层写进 `manga.json`（真实逐字坐标），
/// 不必等 OCR、也没有 OCR 按字数均分字格的偏移。
///
/// 转换完成时（`BookFormatRebuild`）与开书时（补此前导入的卷）各调一次；已提取过
/// （`pdf_text_layer_version` 已记）就什么都不做。
abstract final class MangaPdfTextLayer {
  /// 单测注入点（见 [PdfTextLayerGlyphLoader]）。null = 用真实的 PDFium 实现。
  @visibleForTesting
  static PdfTextLayerGlyphLoader? debugGlyphLoader;

  /// [bookDir] 里有 `document.pdf` 且 `manga.json` 还没提取过文字层时提取并落盘，
  /// 返回落盘后的 payload；不需要 / 失败时返回 null（失败只记日志，下次开书重试）。
  static Future<MokuroPayload?> ensure(String bookDir) async {
    final File pdf = File(p.join(bookDir, PdfImporter.kPdfFileName));
    if (!pdf.existsSync()) return null;
    final String jsonPath = p.join(bookDir, MangaStorage.kMangaJsonFileName);
    try {
      return await runExclusiveOnMangaJson<MokuroPayload?>(jsonPath, () async {
        final File json = File(jsonPath);
        if (!json.existsSync()) return null;
        final MokuroPayload payload = await _parseOffUi(
          await json.readAsString(),
        );
        if (payload.pdfTextLayerVersion != null || payload.images.isEmpty) {
          return null;
        }
        final PdfTextLayerGlyphLoader loader =
            debugGlyphLoader ?? _loadGlyphsWithPdfium;
        final List<List<PdfTextLayerGlyph>> pages = await loader(
          pdf.path,
          <MokuroSize>[
            for (final MokuroImage page in payload.images) page.size,
          ],
        );
        return writeMangaJsonAtomically(
          jsonPath,
          await _applyOffUi(payload, pages),
        );
      });
    } catch (error, stack) {
      ErrorLogService.instance.log('MangaPdfTextLayer.ensure', error, stack);
      return null;
    }
  }

  // 整份 manga.json 解析与几百页的切行分块都可能远超 1 ms：下放 isolate。必须是
  // 静态方法——闭包只捕获参数，不会把调用方作用域里的东西带过 isolate 边界。
  static Future<MokuroPayload> _parseOffUi(String source) =>
      Isolate.run<MokuroPayload>(() => parseMangaJson(source));

  static Future<MokuroPayload> _applyOffUi(
    MokuroPayload payload,
    List<List<PdfTextLayerGlyph>> pages,
  ) => Isolate.run<MokuroPayload>(() => applyPdfTextLayer(payload, pages));

  static Future<List<List<PdfTextLayerGlyph>>> _loadGlyphsWithPdfium(
    String pdfPath,
    List<MokuroSize> pageSizes,
  ) async {
    await PdfEngine.ensureInitialized();
    final PdfDocument document = await PdfDocument.openFile(pdfPath);
    try {
      final List<PdfPage> pages = document.pages;
      if (pages.length != pageSizes.length) {
        // 页数对不上：交给 applyPdfTextLayer 记版本、不套块。
        return <List<PdfTextLayerGlyph>>[
          for (int i = 0; i < pages.length; i++) const <PdfTextLayerGlyph>[],
        ];
      }
      final List<List<PdfTextLayerGlyph>> result = <List<PdfTextLayerGlyph>>[];
      for (int i = 0; i < pages.length; i++) {
        final PdfPage page = pages[i];
        final PdfPageRawText? raw = await page.loadText();
        final MokuroSize size = pageSizes[i];
        if (raw == null || size.isEmpty) {
          result.add(const <PdfTextLayerGlyph>[]);
          continue;
        }
        // toRect 处理了 /Rotate 与 PDF 左下原点 → 页图左上原点；页图是按页面比例
        // 等比栅格化的（PdfEngine.renderPagePng），按页图尺寸缩放即与像素对齐。
        final Size scaled = Size(size.width, size.height);
        result.add(
          pdfTextLayerGlyphs(raw.fullText, <MokuroRect>[
            for (final PdfRect rect in raw.charRects)
              _toMokuro(rect.toRect(page: page, scaledPageSize: scaled)),
          ]),
        );
      }
      return result;
    } finally {
      await document.dispose();
    }
  }

  static MokuroRect _toMokuro(Rect rect) =>
      MokuroRect.fromLTRB(rect.left, rect.top, rect.right, rect.bottom);
}
