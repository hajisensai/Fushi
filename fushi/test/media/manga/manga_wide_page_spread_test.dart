import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_spread_model.dart';

List<List<int>> _flatten(List<MangaSpreadEntry> entries) =>
    entries.map((MangaSpreadEntry e) => e.pageIndices).toList();

List<bool> _solo(int pageCount, Set<int> wide) => <bool>[
  for (int i = 0; i < pageCount; i++) wide.contains(i),
];

void main() {
  group('isMangaWidePage', () {
    test('横向页判宽页，纵向页不判', () {
      expect(isMangaWidePage(width: 2000, height: 1400), isTrue);
      expect(isMangaWidePage(width: 1000, height: 1400), isFalse);
    });

    test('正方形按默认阈值 1.0 算宽页（w/h >= 1）', () {
      expect(isMangaWidePage(width: 1000, height: 1000), isTrue);
    });

    test('阈值可调：抬到 1.4 后普通横页不再误判', () {
      expect(
        isMangaWidePage(width: 1100, height: 1000, ratioThreshold: 1.4),
        isFalse,
      );
      expect(
        isMangaWidePage(width: 1500, height: 1000, ratioThreshold: 1.4),
        isTrue,
      );
    });

    test('缺尺寸（在线页占位）一律判 false，不因坏数据拆散整卷', () {
      expect(isMangaWidePage(width: 0, height: 1400), isFalse);
      expect(isMangaWidePage(width: 1000, height: 0), isFalse);
      expect(isMangaWidePage(width: -1, height: -1), isFalse);
    });
  });

  group('buildMangaSpreads 宽页独占', () {
    test('不传 soloPages 时行为与旧版逐字一致', () {
      final List<List<int>> withArg = _flatten(
        buildMangaSpreads(
          7,
          layout: MangaPageLayout.double,
          spreadOffset: 1,
          soloPages: const <bool>[],
        ),
      );
      final List<List<int>> withoutArg = _flatten(
        buildMangaSpreads(7, layout: MangaPageLayout.double, spreadOffset: 1),
      );
      expect(withArg, withoutArg);
      expect(withArg, <List<int>>[
        <int>[0],
        <int>[1, 2],
        <int>[3, 4],
        <int>[5, 6],
      ]);
    });

    test('宽页独占一屏，并把其后的页序重新对齐', () {
      // 第 3 页是见开き。旧行为会把它配成 [3,4]（宽页缩成半宽，且 4 之后全错位）。
      final List<List<int>> entries = _flatten(
        buildMangaSpreads(
          7,
          layout: MangaPageLayout.double,
          spreadOffset: 1,
          soloPages: _solo(7, <int>{3}),
        ),
      );
      expect(entries, <List<int>>[
        <int>[0],
        <int>[1, 2],
        <int>[3],
        <int>[4, 5],
        <int>[6],
      ]);
    });

    test('宽页前一页也只能独占（否则宽页被拉进配对）', () {
      final List<List<int>> entries = _flatten(
        buildMangaSpreads(
          4,
          layout: MangaPageLayout.double,
          spreadOffset: 0,
          soloPages: _solo(4, <int>{1}),
        ),
      );
      expect(entries, <List<int>>[
        <int>[0],
        <int>[1],
        <int>[2, 3],
      ]);
    });

    test('连续宽页各自独占', () {
      final List<List<int>> entries = _flatten(
        buildMangaSpreads(
          4,
          layout: MangaPageLayout.double,
          spreadOffset: 0,
          soloPages: _solo(4, <int>{1, 2}),
        ),
      );
      expect(entries, <List<int>>[
        <int>[0],
        <int>[1],
        <int>[2],
        <int>[3],
      ]);
    });

    test('单页布局忽略宽页表（本来就一页一屏）', () {
      final List<List<int>> entries = _flatten(
        buildMangaSpreads(
          3,
          layout: MangaPageLayout.single,
          spreadOffset: 1,
          soloPages: _solo(3, <int>{0, 1, 2}),
        ),
      );
      expect(entries, <List<int>>[
        <int>[0],
        <int>[1],
        <int>[2],
      ]);
    });

    test('soloPages 比页数短时越界视为普通页，不抛', () {
      final List<List<int>> entries = _flatten(
        buildMangaSpreads(
          5,
          layout: MangaPageLayout.double,
          spreadOffset: 0,
          soloPages: const <bool>[false, true],
        ),
      );
      expect(entries, <List<int>>[
        <int>[0],
        <int>[1],
        <int>[2, 3],
        <int>[4],
      ]);
    });

    test('无论宽页怎么分布，每页恰好出现一次且升序', () {
      for (final Set<int> wide in <Set<int>>[
        <int>{},
        <int>{0},
        <int>{5},
        <int>{1, 4},
        <int>{0, 1, 2, 3, 4, 5, 6, 7},
      ]) {
        for (final int offset in <int>[0, 1]) {
          final List<int> flat = buildMangaSpreads(
            8,
            layout: MangaPageLayout.double,
            spreadOffset: offset,
            soloPages: _solo(8, wide),
          ).expand((MangaSpreadEntry e) => e.pageIndices).toList();
          expect(flat, <int>[
            0,
            1,
            2,
            3,
            4,
            5,
            6,
            7,
          ], reason: 'wide=$wide offset=$offset 丢页或乱序');
        }
      }
    });
  });

  group('跨页偏移', () {
    test('offset 1 = 封面独占（日漫惯例，旧行为）', () {
      expect(
        _flatten(
          buildMangaSpreads(5, layout: MangaPageLayout.double, spreadOffset: 1),
        ),
        <List<int>>[
          <int>[0],
          <int>[1, 2],
          <int>[3, 4],
        ],
      );
    });

    test('offset 0 = 从第一页起配对（左右页整卷反过来）', () {
      expect(
        _flatten(
          buildMangaSpreads(5, layout: MangaPageLayout.double, spreadOffset: 0),
        ),
        <List<int>>[
          <int>[0, 1],
          <int>[2, 3],
          <int>[4],
        ],
      );
    });
  });
}
