import 'dart:async';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:pdfrx/pdfrx.dart';

import 'package:fushi/src/epub/book_file_location.dart';
import 'package:fushi/src/pdf/pdf_engine.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// PDF 有声书的「正文」：文本层逐页全文，第 i 页（0 起）= 匹配器的 section i。
///
/// 导入 / 重匹配（经引擎 `loadBookTextSections` 的宿主注入点）与 PDF 阅读器高亮
/// 必须读**同一份**文本：两边都用 `PdfPage.loadStructuredText().fullText`。匹配器给出的
/// 是该文本归一化后的偏移，阅读器再用同一套归一化（[AudioTextNormalizer.
/// normalizeWithOffsets]）换回 `fullText` 的码元下标，而 `fullText` 与 `charRects`
/// 逐码元对齐——任何一边换成 `loadText()`（原始顺序）都会让偏移错位。

/// PDF 页 section 的 href（匹配器只拿它当标签写进 `AudioCue.chapterHref`；PDF 定位
/// 一律走 `textFragmentId` 里的 `s=` 页码，不解析 href）。
String pdfPageSectionHref(int pageIndex) => 'pdf-page-${pageIndex + 1}';

/// 读一本 PDF 书的逐页文本层，按页序返回 [EpubSection]（下标 = 0 起页码）。
///
/// 某页文本层读失败只记日志、该页按空文本占位：section 下标必须与页码一一对应，
/// 漏掉一页会让其后所有页的高亮错位一页。扫描图 PDF（无文本层）得到全空 section，
/// 匹配器 0 命中，有声书照常能播、只是没有正文高亮。
Future<List<EpubSection>> loadPdfTextSections(EpubBookRow row) async {
  await PdfEngine.ensureInitialized();
  final PdfDocument document = await PdfDocument.openFile(
    bookMainFilePath(row),
  );
  try {
    final List<PdfPage> pages = document.pages;
    final List<EpubSection> sections = <EpubSection>[];
    for (int i = 0; i < pages.length; i++) {
      String text = '';
      try {
        text = (await pages[i].loadStructuredText()).fullText;
      } catch (e, stack) {
        ErrorLogService.instance.log('PdfTextSections.loadPage', e, stack);
      }
      sections.add(
        EpubSection(index: i, href: pdfPageSectionHref(i), text: text),
      );
    }
    return sections;
  } finally {
    await document.dispose();
  }
}

/// 匹配器的归一化区间 `[normStart, normEnd)` → 页文本 `fullText` 的码元区间
/// `[start, end)`（含被归一化剥掉的标点 / 换行，高亮整句不缺口）。
///
/// [normalized] 必须是同一页 `fullText` 的 [AudioTextNormalizer.normalizeWithOffsets]
/// 结果。区间越界（文本层变了、cue 是别的书的）或为空时返回 null，调用方不画高亮。
({int start, int end})? pdfRawRangeForNormRange(
  NormalizedTextWithOffsets normalized, {
  required int normStart,
  required int normEnd,
}) {
  if (normStart < 0 ||
      normEnd <= normStart ||
      normEnd > normalized.text.length) {
    return null;
  }
  return (
    start: normalized.starts[normStart],
    end: normalized.ends[normEnd - 1],
  );
}

/// 一句字幕落在某一页上的归一化区间（[page] 0 起，区间相对该页归一化文本）。
typedef PdfCuePageSpan = ({int page, int normStart, int normEnd});

/// 把匹配器给的区间按页拆开。PDF 正文按页切成 section，句子常跨页尾：匹配器把整句
/// 记在**起始页**上（`s=` 是起始页），`normEnd` 按全书拼接坐标（各页归一化文本首尾
/// 相接）越过该页长度，越过的部分顺延到后续页。只画起始页会让跨页句的后半截没有
/// 高亮；按 `normEnd > 页长` 直接判越界则整句都不画。
///
/// [normLengthOf] 返回某页归一化文本长度（与匹配器同一套归一化）；返回 null = 该页
/// 文本层读不到，后面的页无从换算，到此为止。起始页装不下 [normStart]（文本层变了、
/// cue 属于别的书）时返回空表，不画。
Future<List<PdfCuePageSpan>> pdfSplitCueRangeAcrossPages({
  required int startPage,
  required int normStart,
  required int normEnd,
  required int pageCount,
  required FutureOr<int?> Function(int page) normLengthOf,
}) async {
  final List<PdfCuePageSpan> spans = <PdfCuePageSpan>[];
  if (startPage < 0 || normStart < 0 || normEnd <= normStart) return spans;
  int start = normStart;
  int end = normEnd;
  for (int page = startPage; page < pageCount && end > 0; page++) {
    final int? len = await normLengthOf(page);
    if (len == null) break;
    if (page == startPage && start >= len) return <PdfCuePageSpan>[];
    final int segEnd = end < len ? end : len;
    if (start < segEnd) {
      spans.add((page: page, normStart: start, normEnd: segEnd));
    }
    start = start > len ? start - len : 0;
    end -= len;
  }
  return spans;
}
