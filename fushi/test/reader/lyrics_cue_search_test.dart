import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/reader/lyrics_cue_search.dart';

/// 歌词模式「搜索字幕」的纯函数：与库页搜索同一归一化口径
/// （[normalizeMediaSearchText]），命中区间映射回原文供高亮，结果上限与总数。
void main() {
  group('mediaSearchMatchRange（归一化后命中 → 原文区间）', () {
    test('片假名 / 平假名互搜，区间落在原文的片假名上', () {
      const String text = 'しまむらがアダチを見た';
      final ({int start, int end})? r = mediaSearchMatchRange(text, 'あだち');
      expect(r, isNotNull);
      expect(text.substring(r!.start, r.end), 'アダチ');
    });

    test('全角 ASCII 与大小写折叠', () {
      const String text = '第ＡＢＣ話';
      final ({int start, int end})? r = mediaSearchMatchRange(text, 'abc');
      expect(text.substring(r!.start, r.end), 'ＡＢＣ');
    });

    test('被丢弃的标点 / 空白跨在命中中间时一并高亮', () {
      const String text = '「安達・しまむら」と言った';
      final ({int start, int end})? r = mediaSearchMatchRange(text, '安達しまむら');
      expect(text.substring(r!.start, r.end), '安達・しまむら');
    });

    test('代理对（补充平面汉字）不切半', () {
      const String text = 'あの𠮷野家で';
      final ({int start, int end})? r = mediaSearchMatchRange(text, '𠮷野');
      expect(text.substring(r!.start, r.end), '𠮷野');
      final ({int start, int end})? r2 = mediaSearchMatchRange(text, '野家');
      expect(text.substring(r2!.start, r2.end), '野家');
    });

    test('不命中 / 归一化后空查询 → null', () {
      expect(mediaSearchMatchRange('しまむら', 'あだち'), isNull);
      expect(mediaSearchMatchRange('しまむら', ' ・ '), isNull);
    });
  });

  group('searchLyricsCueTexts', () {
    test('按书内顺序列出命中句，命中判据与 matchesMediaSearch 一致', () {
      const List<String> texts = <String>[
        '桜が咲いた',
        'しまむらはアダチを見た',
        '体育館の二階',
        '安達はしまむらを見た',
      ];
      final LyricsCueTextSearch found = searchLyricsCueTexts(texts, 'あだち');
      expect(found.hits.map((LyricsCueTextHit h) => h.cueIndex), <int>[1]);
      expect(found.total, 1);
      expect(found.truncated, isFalse);
      for (int i = 0; i < texts.length; i++) {
        expect(
          found.hits.any((LyricsCueTextHit h) => h.cueIndex == i),
          matchesMediaSearch(query: 'あだち', titles: <String>[texts[i]]),
          reason: texts[i],
        );
      }
      final LyricsCueTextSearch both = searchLyricsCueTexts(texts, 'シマムラ');
      expect(both.hits.map((LyricsCueTextHit h) => h.cueIndex), <int>[1, 3]);
      final LyricsCueTextHit last = both.hits.last;
      expect(texts[3].substring(last.matchStart, last.matchEnd), 'しまむら');
    });

    test('超过上限只列前 N 条，total 仍是全部命中数', () {
      final List<String> texts = <String>[
        for (int i = 0; i < 10162; i++) i.isEven ? '第$i句 しまむら' : '第$i句 安達',
      ];
      final LyricsCueTextSearch found = searchLyricsCueTexts(texts, 'しまむら');
      expect(found.total, 5081);
      expect(found.hits.length, kLyricsCueSearchMaxResults);
      expect(found.truncated, isTrue);
      expect(found.hits.first.cueIndex, 0);
      expect(found.hits.last.cueIndex, (kLyricsCueSearchMaxResults - 1) * 2);
      final LyricsCueTextSearch small = searchLyricsCueTexts(
        texts,
        'しまむら',
        limit: 3,
      );
      expect(small.hits.map((LyricsCueTextHit h) => h.cueIndex), <int>[
        0,
        2,
        4,
      ]);
    });

    test('空查询 / 纯标点查询 → 空结果（不把全书都列出来）', () {
      const List<String> texts = <String>['しまむら', '安達'];
      expect(searchLyricsCueTexts(texts, '').total, 0);
      expect(searchLyricsCueTexts(texts, '   ').hits, isEmpty);
    });

    test('isolate 版与同步版结果一致', () async {
      const List<String> texts = <String>['しまむら', 'アダチ', '安達としまむら'];
      final LyricsCueTextSearch sync = searchLyricsCueTexts(texts, 'しまむら');
      final LyricsCueTextSearch off = await searchLyricsCueTextsOffUi(
        texts,
        'しまむら',
      );
      expect(off.total, sync.total);
      expect(
        off.hits.map((LyricsCueTextHit h) => (h.cueIndex, h.matchStart)),
        sync.hits.map((LyricsCueTextHit h) => (h.cueIndex, h.matchStart)),
      );
    });
  });
}
