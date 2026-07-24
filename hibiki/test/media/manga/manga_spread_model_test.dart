import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/manga/manga_spread_model.dart';

/// Flatten entries into a [pageIndices...] list-of-lists for easy comparison.
List<List<int>> _flatten(List<MangaSpreadEntry> entries) =>
    entries.map((MangaSpreadEntry e) => e.pageIndices).toList();

void main() {
  group('MangaSpreadEntry.isSpread', () {
    test('two indices is a spread, one is not', () {
      expect(const MangaSpreadEntry(<int>[0, 1]).isSpread, isTrue);
      expect(const MangaSpreadEntry(<int>[0]).isSpread, isFalse);
    });
  });

  group('buildMangaSpreads — single layout', () {
    test('each page is its own entry', () {
      final List<MangaSpreadEntry> entries = buildMangaSpreads(
        3,
        layout: MangaPageLayout.single,
        spreadOffset: 0,
      );
      expect(_flatten(entries), <List<int>>[
        <int>[0],
        <int>[1],
        <int>[2],
      ]);
    });

    test('single layout ignores spreadOffset', () {
      final List<MangaSpreadEntry> entries = buildMangaSpreads(
        2,
        layout: MangaPageLayout.single,
        spreadOffset: 1,
      );
      expect(_flatten(entries), <List<int>>[
        <int>[0],
        <int>[1],
      ]);
    });
  });

  group('buildMangaSpreads — double layout, offset 0', () {
    test('even count pairs cleanly', () {
      final List<MangaSpreadEntry> entries = buildMangaSpreads(
        4,
        layout: MangaPageLayout.double,
        spreadOffset: 0,
      );
      expect(_flatten(entries), <List<int>>[
        <int>[0, 1],
        <int>[2, 3],
      ]);
    });

    test('odd count leaves the last page solo', () {
      final List<MangaSpreadEntry> entries = buildMangaSpreads(
        5,
        layout: MangaPageLayout.double,
        spreadOffset: 0,
      );
      expect(_flatten(entries), <List<int>>[
        <int>[0, 1],
        <int>[2, 3],
        <int>[4],
      ]);
    });
  });

  group('buildMangaSpreads — double layout, offset 1', () {
    test('cover page stands alone, rest pair', () {
      final List<MangaSpreadEntry> entries = buildMangaSpreads(
        5,
        layout: MangaPageLayout.double,
        spreadOffset: 1,
      );
      expect(_flatten(entries), <List<int>>[
        <int>[0],
        <int>[1, 2],
        <int>[3, 4],
      ]);
    });

    test('offset 1 with even count leaves a solo tail too', () {
      final List<MangaSpreadEntry> entries = buildMangaSpreads(
        4,
        layout: MangaPageLayout.double,
        spreadOffset: 1,
      );
      expect(_flatten(entries), <List<int>>[
        <int>[0],
        <int>[1, 2],
        <int>[3],
      ]);
    });
  });

  group('buildMangaSpreads — edge cases', () {
    test('zero / negative page count is empty', () {
      expect(
        buildMangaSpreads(0, layout: MangaPageLayout.double, spreadOffset: 0),
        isEmpty,
      );
      expect(
        buildMangaSpreads(-3, layout: MangaPageLayout.double, spreadOffset: 0),
        isEmpty,
      );
    });

    test('single page double-layout is one solo entry', () {
      final List<MangaSpreadEntry> entries = buildMangaSpreads(
        1,
        layout: MangaPageLayout.double,
        spreadOffset: 0,
      );
      expect(_flatten(entries), <List<int>>[
        <int>[0],
      ]);
    });

    test('negative spreadOffset normalises to 0', () {
      final List<MangaSpreadEntry> entries = buildMangaSpreads(
        2,
        layout: MangaPageLayout.double,
        spreadOffset: -5,
      );
      expect(_flatten(entries), <List<int>>[
        <int>[0, 1],
      ]);
    });

    test('every page index appears exactly once, in ascending order', () {
      final List<MangaSpreadEntry> entries = buildMangaSpreads(
        7,
        layout: MangaPageLayout.double,
        spreadOffset: 1,
      );
      final List<int> flat =
          entries.expand((MangaSpreadEntry e) => e.pageIndices).toList();
      expect(flat, <int>[0, 1, 2, 3, 4, 5, 6]);
    });
  });
}
