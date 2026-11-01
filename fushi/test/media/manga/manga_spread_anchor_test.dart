// 反馈 haetN22fJI：双页配对错位时「错开一页」无效；旋转进双页时应以当前聚焦页
// 定位配对。根因：buildMangaSpreads 的偏移只作用于首段（卷首到第一张宽页），
// 宽页之后的段一律从段首配对，与偏移无关。现在配对按段进行，锚点段与首段都受
// 偏移支配；锚点由阅读器在旋转进双页 / 后段拨开关时设定。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_spread_model.dart';

List<List<int>> _flatten(List<MangaSpreadEntry> entries) =>
    entries.map((MangaSpreadEntry e) => e.pageIndices).toList();

List<bool> _solo(int pageCount, Set<int> wide) => <bool>[
  for (int i = 0; i < pageCount; i++) wide.contains(i),
];

List<List<int>> _build(
  int pageCount, {
  required int offset,
  Set<int> wide = const <int>{},
  int anchor = -1,
}) => _flatten(
  buildMangaSpreads(
    pageCount,
    layout: MangaPageLayout.double,
    spreadOffset: offset,
    soloPages: _solo(pageCount, wide),
    anchorPage: anchor,
  ),
);

/// 第 [page] 页所在的那一对。
List<int> _pairOf(List<List<int>> entries, int page) =>
    entries.firstWhere((List<int> e) => e.contains(page));

/// 独占页 [page] 那个 entry 的序号（List 没有值相等，不能用 indexOf）。
int _soloAt(List<List<int>> entries, int page) =>
    entries.indexWhere((List<int> e) => e.length == 1 && e.single == page);

void main() {
  group('根因复现：宽页之后的配对与偏移无关', () {
    test('无锚点时宽页之后的段两种偏移结果相同（旧行为，保留为默认）', () {
      // 第 2 页是见开き。偏移只改首段。
      final List<List<int>> on = _build(10, offset: 1, wide: <int>{2});
      final List<List<int>> off = _build(10, offset: 0, wide: <int>{2});
      expect(on.sublist(_soloAt(on, 2)), <List<int>>[
        <int>[2],
        <int>[3, 4],
        <int>[5, 6],
        <int>[7, 8],
        <int>[9],
      ]);
      expect(off.sublist(_soloAt(off, 2)), on.sublist(_soloAt(on, 2)));
    });

    test('后段有锚点时偏移作用到该段：拨开关会错开眼前这一对', () {
      // 读者停在 [5,6]，阅读器把 5 记成锚点（按偏移 1 与现状一致），然后偏移翻成 0。
      final List<List<int>> before = _build(
        10,
        offset: 1,
        wide: <int>{2},
        anchor: 5,
      );
      expect(_pairOf(before, 5), <int>[5, 6]);
      final List<List<int>> after = _build(
        10,
        offset: 0,
        wide: <int>{2},
        anchor: 5,
      );
      expect(_pairOf(after, 5), <int>[4, 5]);
      expect(_pairOf(after, 6), <int>[6, 7]);
      // 宽页之后的段首 3 落单，段尾 9 与 8 配对。
      expect(after.sublist(_soloAt(after, 2)), <List<int>>[
        <int>[2],
        <int>[3],
        <int>[4, 5],
        <int>[6, 7],
        <int>[8, 9],
      ]);
    });
  });

  group('锚点段：锚点页做前页', () {
    test('无宽页时锚点覆盖封面惯例，偏移 0 把锚点错开成后页', () {
      expect(_build(6, offset: 1, anchor: 2), <List<int>>[
        <int>[0, 1],
        <int>[2, 3],
        <int>[4, 5],
      ]);
      expect(_build(6, offset: 0, anchor: 2), <List<int>>[
        <int>[0],
        <int>[1, 2],
        <int>[3, 4],
        <int>[5],
      ]);
    });

    test('锚点落在独占页上等于没有锚点', () {
      expect(
        _build(8, offset: 1, wide: <int>{3}, anchor: 3),
        _build(8, offset: 1, wide: <int>{3}),
      );
    });

    test('每种锚点 / 偏移组合下每页恰好出现一次且升序', () {
      for (int anchor = -1; anchor < 9; anchor++) {
        for (final int offset in <int>[0, 1]) {
          final List<int> flat = _build(
            9,
            offset: offset,
            wide: <int>{4},
            anchor: anchor,
          ).expand((List<int> e) => e).toList();
          expect(flat, List<int>.generate(9, (int i) => i));
        }
      }
    });
  });

  group('mangaSpreadAnchorLeading：旋转进双页时聚焦页做前页', () {
    test('两种偏移下聚焦页都落在一对的前页', () {
      for (final int offset in <int>[0, 1]) {
        for (final int focus in <int>[1, 2, 5, 6, 8]) {
          final int anchor = mangaSpreadAnchorLeading(
            focus,
            pageCount: 10,
            spreadOffset: offset,
          );
          final List<List<int>> entries = _build(
            10,
            offset: offset,
            anchor: anchor,
          );
          final List<int> pair = _pairOf(entries, focus);
          expect(
            pair.first,
            focus,
            reason: 'offset=$offset focus=$focus → $pair',
          );
          if (focus < 9) expect(pair, <int>[focus, focus + 1]);
        }
      }
    });

    test('段尾页（后面没有页可配）仍做前页：独占', () {
      final int anchor = mangaSpreadAnchorLeading(
        9,
        pageCount: 10,
        spreadOffset: 0,
      );
      expect(_pairOf(_build(10, offset: 0, anchor: anchor), 9), <int>[9]);
    });

    test('宽页 / 越界 / 单页段没有可定位的配对', () {
      expect(
        mangaSpreadAnchorLeading(
          3,
          pageCount: 8,
          spreadOffset: 1,
          soloPages: _solo(8, <int>{3}),
        ),
        -1,
      );
      expect(mangaSpreadAnchorLeading(12, pageCount: 8, spreadOffset: 1), -1);
      expect(
        mangaSpreadAnchorLeading(
          3,
          pageCount: 8,
          spreadOffset: 1,
          soloPages: _solo(8, <int>{2, 4}),
        ),
        -1,
      );
    });
  });

  test('mangaSpreadRunOf 按独占页切段', () {
    final List<bool> solo = _solo(10, <int>{2, 6});
    expect(mangaSpreadRunOf(0, 10, solo), (0, 2));
    expect(mangaSpreadRunOf(4, 10, solo), (3, 6));
    expect(mangaSpreadRunOf(9, 10, solo), (7, 10));
    expect(mangaSpreadRunOf(2, 10, solo), isNull);
  });
}
