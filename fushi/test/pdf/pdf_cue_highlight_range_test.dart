import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pdf/pdf_text_sections.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// PDF 有声书字幕句高亮：匹配器给的是页文本层**归一化后**的区间，阅读器要换回
/// `fullText` 的码元区间（`fullText` 与 `charRects` 逐码元对齐，才能取到字符矩形）。
///
/// 归一化映射由 Rust 折叠内核产出（[AudioTextNormalizer.normalizeWithOffsets]），这里
/// 手写同形的映射，钉住「归一化区间 → 原文区间」的换算本身。
void main() {
  // 原文：「こんにちは」\n世界。
  //  下标：0 「 1 こ 2 ん 3 に 4 ち 5 は 6 」 7 \n 8 世 9 界 10 。
  const String raw = '「こんにちは」\n世界。';
  const NormalizedTextWithOffsets normalized = NormalizedTextWithOffsets(
    'こんにちは世界',
    <int>[1, 2, 3, 4, 5, 8, 9],
    <int>[2, 3, 4, 5, 6, 9, 10],
  );

  test('整句：从首个保留字到末个保留字，中间被剥掉的标点 / 换行一并覆盖', () {
    final ({int start, int end})? range = pdfRawRangeForNormRange(
      normalized,
      normStart: 0,
      normEnd: 7,
    );
    expect(range, isNotNull);
    expect(raw.substring(range!.start, range.end), 'こんにちは」\n世界');
  });

  test('句子落在页中段：只取对应那一截', () {
    final ({int start, int end})? range = pdfRawRangeForNormRange(
      normalized,
      normStart: 5,
      normEnd: 7,
    );
    expect(range, (start: 8, end: 10));
    expect(raw.substring(range!.start, range.end), '世界');
  });

  test('空区间 / 越界（文本层变了、cue 属于别的书）不画', () {
    expect(
      pdfRawRangeForNormRange(normalized, normStart: 3, normEnd: 3),
      isNull,
    );
    expect(
      pdfRawRangeForNormRange(normalized, normStart: -1, normEnd: 2),
      isNull,
    );
    expect(
      pdfRawRangeForNormRange(normalized, normStart: 2, normEnd: 8),
      isNull,
    );
  });

  test('section href 只是 1 起页码标签，定位一律走 textFragmentId 的 s=', () {
    expect(pdfPageSectionHref(0), 'pdf-page-1');
    expect(pdfPageSectionHref(41), 'pdf-page-42');
  });
}
