import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pdf/pdf_text_search.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:pdfrx/pdfrx.dart';

/// PDF 全文搜索（拍板台 KN4kdP4JB8）：只搜文本层、跨行命中、结果流式出现、上一个 /
/// 下一个回绕、无文本层明确判出来。
///
/// 真归一化是 Rust 折叠内核（[AudioTextNormalizer.normalizeWithOffsets]），这里注入
/// 同形的手写映射：剥掉换行 / 空格 / 句读 / 括号，其余逐码元保留——钉住的是「归一化
/// 坐标里找、换回原文区间」这套换算本身。
NormalizedTextWithOffsets _fakeNormalize(String s) {
  const String skipped = '\n\r 　。、「」';
  final StringBuffer text = StringBuffer();
  final List<int> starts = <int>[];
  final List<int> ends = <int>[];
  for (int i = 0; i < s.length; i++) {
    if (skipped.contains(s[i])) continue;
    text.write(s[i]);
    starts.add(i);
    ends.add(i + 1);
  }
  return NormalizedTextWithOffsets(text.toString(), starts, ends);
}

/// 把每页文本包成搜索素材；矩形按码元区间编码，便于断言。
PdfSearchPageLoader _loaderFor(List<String?> pages) {
  return (int pageIndex) async {
    final String? text = pages[pageIndex];
    if (text == null) return null;
    return (
      fullText: text,
      rectsFor: (int start, int end) => <PdfRect>[
        PdfRect(start.toDouble(), 10, end.toDouble(), 0),
      ],
    );
  };
}

void main() {
  group('pdfFindQueryInPage', () {
    test('跨行命中：文本层按行断开的一句话也能找到，区间含中间的换行', () {
      const String raw = '「こんに\nちは」世界';
      final List<({int start, int end})> hits = pdfFindQueryInPage(
        fullText: raw,
        normalized: _fakeNormalize(raw),
        normalizedQuery: _fakeNormalize('こんにちは').text,
        rawQuery: 'こんにちは',
      );
      expect(hits, hasLength(1));
      expect(raw.substring(hits.single.start, hits.single.end), 'こんに\nちは');
    });

    test('一页多处命中按出现顺序、不重叠', () {
      const String raw = 'ああああ';
      final List<({int start, int end})> hits = pdfFindQueryInPage(
        fullText: raw,
        normalized: _fakeNormalize(raw),
        normalizedQuery: 'ああ',
        rawQuery: 'ああ',
      );
      expect(hits, <({int start, int end})>[
        (start: 0, end: 2),
        (start: 2, end: 4),
      ]);
    });

    test('查询归一化后为空（全是标点）时退回原文字面匹配', () {
      const String raw = '「一」と「二」';
      final List<({int start, int end})> hits = pdfFindQueryInPage(
        fullText: raw,
        normalized: _fakeNormalize(raw),
        normalizedQuery: '',
        rawQuery: '「',
      );
      expect(hits, <({int start, int end})>[
        (start: 0, end: 1),
        (start: 4, end: 5),
      ]);
    });
  });

  group('pdfSearchSnippet', () {
    test('剥掉换行，命中区间随之平移，截断处补省略号', () {
      const String raw = '0123456789\nABCDEFG\nhijklmn';
      final int start = raw.indexOf('CD');
      final ({String text, int matchStart, int matchEnd}) s = pdfSearchSnippet(
        raw,
        start: start,
        end: start + 2,
        radius: 4,
      );
      expect(s.text, '…9ABCDEFG…');
      expect(s.text.substring(s.matchStart, s.matchEnd), 'CD');
    });

    test('命中跨换行：片段里命中连成一段', () {
      const String raw = 'あい\nうえ';
      final ({String text, int matchStart, int matchEnd}) s = pdfSearchSnippet(
        raw,
        start: 1,
        end: 4,
      );
      expect(s.text, 'あいうえ');
      expect(s.text.substring(s.matchStart, s.matchEnd), 'いう');
    });

    test('命中在页尾：区间收到片段末尾', () {
      const String raw = 'abcdef';
      final ({String text, int matchStart, int matchEnd}) s = pdfSearchSnippet(
        raw,
        start: 4,
        end: 6,
        radius: 2,
      );
      expect(s.text, '…cdef');
      expect(s.text.substring(s.matchStart, s.matchEnd), 'ef');
    });

    test('截取边界不切开代理对（扩展 B 汉字 / emoji）', () {
      // '𠮟' 是两个码元；radius 恰好落在它的两半之间。
      const String raw = 'x𠮟abcd𠮟y';
      final int start = raw.indexOf('ab');
      final ({String text, int matchStart, int matchEnd}) s = pdfSearchSnippet(
        raw,
        start: start,
        end: start + 4,
        radius: 1,
      );
      expect(s.text, '…𠮟abcd𠮟…');
      expect(s.text.substring(s.matchStart, s.matchEnd), 'abcd');
    });
  });

  group('PdfTextSearchController', () {
    PdfTextSearchController controllerFor(
      List<String?> pages, {
      int maxHits = PdfTextSearchController.kPdfSearchMaxHits,
    }) {
      final PdfTextSearchController c = PdfTextSearchController(
        loadPage: _loaderFor(pages),
        normalize: _fakeNormalize,
        maxHits: maxHits,
      );
      addTearDown(c.dispose);
      return c;
    }

    test('逐页找命中：结果按页序、带页码 / 矩形 / 片段，按页可查下标', () async {
      final PdfTextSearchController c = controllerFor(<String?>[
        '猫がいる',
        '犬\nと猫',
        '何もない',
        '猫猫',
      ]);
      await c.search(' 猫 ', pageCount: 4);
      expect(c.status, PdfTextSearchStatus.done);
      expect(c.query, '猫');
      expect(c.hits.map((PdfTextSearchHit h) => h.pageIndex), <int>[
        0,
        1,
        3,
        3,
      ]);
      expect(c.hitIndicesOnPage(3), <int>[2, 3]);
      expect(c.hitIndicesOnPage(2), isEmpty);
      final PdfTextSearchHit second = c.hits[1];
      expect((second.start, second.end), (3, 4));
      expect(second.rects.single.left, 3);
      expect(
        second.snippet.substring(
          second.snippetMatchStart,
          second.snippetMatchEnd,
        ),
        '猫',
      );
      expect(c.searchedPages, 4);
      expect(c.currentIndex, isNull);
    });

    test('上一个 / 下一个回绕；select 越界不变', () async {
      final PdfTextSearchController c = controllerFor(<String?>['aXbXcX']);
      await c.search('X', pageCount: 1);
      expect(c.next()?.start, 1);
      expect(c.next()?.start, 3);
      expect(c.next()?.start, 5);
      expect(c.next()?.start, 1);
      expect(c.previous()?.start, 5);
      expect(c.select(9), isNull);
      expect(c.currentIndex, 2);
    });

    test('还没选时「上一个」从末条开始', () async {
      final PdfTextSearchController c = controllerFor(<String?>['aXbX']);
      await c.search('X', pageCount: 1);
      expect(c.previous()?.start, 3);
    });

    test('整本没有文本层（扫描图）→ noTextLayer，而不是「没找到」', () async {
      final PdfTextSearchController c = controllerFor(<String?>['', ' \n', '']);
      await c.search('猫', pageCount: 3);
      expect(c.status, PdfTextSearchStatus.noTextLayer);
      expect(c.hasHits, isFalse);
    });

    test('部分页没有文本层：照常搜有字的页，判 done', () async {
      final PdfTextSearchController c = controllerFor(<String?>['', '猫']);
      await c.search('猫', pageCount: 2);
      expect(c.status, PdfTextSearchStatus.done);
      expect(c.hits.single.pageIndex, 1);
    });

    test('每页文本层都读失败 → failed；同一查询可以重试', () async {
      final PdfTextSearchController c = controllerFor(<String?>[null, null]);
      await c.search('猫', pageCount: 2);
      expect(c.status, PdfTextSearchStatus.failed);
      int notified = 0;
      c.addListener(() => notified++);
      await c.search('猫', pageCount: 2);
      expect(notified, greaterThan(0));
    });

    test('命中达到上限即停，标记 truncated', () async {
      final PdfTextSearchController c = controllerFor(<String?>[
        'XXX',
        'XXX',
      ], maxHits: 4);
      await c.search('X', pageCount: 2);
      expect(c.hits, hasLength(4));
      expect(c.truncated, isTrue);
      expect(c.status, PdfTextSearchStatus.done);
    });

    test('新搜索作废正在跑的旧搜索，旧结果不混进来', () async {
      final Completer<void> gate = Completer<void>();
      final PdfTextSearchController c = PdfTextSearchController(
        loadPage: (int page) async {
          if (page == 0) await gate.future;
          return (
            fullText: '猫犬',
            rectsFor: (int s, int e) => const <PdfRect>[],
          );
        },
        normalize: _fakeNormalize,
      );
      addTearDown(c.dispose);
      final Future<void> first = c.search('猫', pageCount: 2);
      expect(c.status, PdfTextSearchStatus.searching);
      final Future<void> second = c.search('犬', pageCount: 2);
      gate.complete();
      await Future.wait(<Future<void>>[first, second]);
      expect(c.query, '犬');
      expect(c.hits.map((PdfTextSearchHit h) => h.start), <int>[1, 1]);
      expect(c.status, PdfTextSearchStatus.done);
    });

    test('空查询 = 清空；clear 后回到 idle、页上不再有命中', () async {
      final PdfTextSearchController c = controllerFor(<String?>['猫']);
      await c.search('猫', pageCount: 1);
      c.next();
      await c.search('   ', pageCount: 1);
      expect(c.status, PdfTextSearchStatus.idle);
      expect(c.hasHits, isFalse);
      expect(c.currentIndex, isNull);
      expect(c.hitIndicesOnPage(0), isEmpty);
    });

    test('同一查询已搜完时重提交不重搜（保留当前命中）', () async {
      int loads = 0;
      final PdfTextSearchController c = PdfTextSearchController(
        loadPage: (int page) async {
          loads++;
          return (fullText: '猫', rectsFor: (int s, int e) => const <PdfRect>[]);
        },
        normalize: _fakeNormalize,
      );
      addTearDown(c.dispose);
      await c.search('猫', pageCount: 1);
      c.next();
      await c.search('猫', pageCount: 1);
      expect(loads, 1);
      expect(c.currentIndex, 0);
    });
  });
}
