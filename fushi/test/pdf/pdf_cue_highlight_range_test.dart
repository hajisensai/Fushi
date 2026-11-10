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

  group('跨页句按页拆（匹配器把整句记在起始页，ne 顺延到后续页）', () {
    // 各页归一化长度：第 0 页 10、第 1 页 0（空页 / 插图页）、第 2 页 8、第 3 页 5。
    const List<int> lens = <int>[10, 0, 8, 5];
    Future<List<PdfCuePageSpan>> split(
      int startPage,
      int ns,
      int ne, {
      int? Function(int page)? lengthOf,
    }) => pdfSplitCueRangeAcrossPages(
      startPage: startPage,
      normStart: ns,
      normEnd: ne,
      pageCount: lens.length,
      normLengthOf: lengthOf ?? (int page) => lens[page],
    );

    test('句子整段在一页内：只有这一页', () async {
      expect(await split(0, 2, 6), <PdfCuePageSpan>[
        (page: 0, normStart: 2, normEnd: 6),
      ]);
    });

    test('跨页句：起始页取到页尾，越过的部分跳过空页落到下一页页首', () async {
      expect(await split(0, 7, 14), <PdfCuePageSpan>[
        (page: 0, normStart: 7, normEnd: 10),
        (page: 2, normStart: 0, normEnd: 4),
      ]);
    });

    test('句子跨三页：中间页整页高亮', () async {
      expect(await split(0, 9, 20), <PdfCuePageSpan>[
        (page: 0, normStart: 9, normEnd: 10),
        (page: 2, normStart: 0, normEnd: 8),
        (page: 3, normStart: 0, normEnd: 2),
      ]);
    });

    test('后续页文本层读不到：只画读得到的前几页', () async {
      expect(
        await split(0, 7, 14, lengthOf: (int page) => page == 0 ? 10 : null),
        <PdfCuePageSpan>[(page: 0, normStart: 7, normEnd: 10)],
      );
    });

    test('起始页装不下句首 / 空区间 / 负页码（文本层变了、cue 属于别的书）不画', () async {
      expect(await split(0, 10, 12), isEmpty);
      expect(await split(0, 3, 3), isEmpty);
      expect(await split(-1, 0, 2), isEmpty);
    });
  });

  test('section href 只是 1 起页码标签，定位一律走 textFragmentId 的 s=', () {
    expect(pdfPageSectionHref(0), 'pdf-page-1');
    expect(pdfPageSectionHref(41), 'pdf-page-42');
  });
}
