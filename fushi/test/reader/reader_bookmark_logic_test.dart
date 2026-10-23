import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_bookmark_logic.dart';
import 'package:fushi_audio/fushi_audio.dart';

Bookmark _bm({
  int section = 2,
  int normCharOffset = 0,
  int charOffset = -1,
  DateTime? createdAt,
  int? id,
}) => Bookmark(
  id: id,
  sectionIndex: section,
  normCharOffset: normCharOffset,
  label: 'ch',
  createdAt: createdAt ?? DateTime(2026, 10, 23),
  charOffset: charOffset,
);

void main() {
  group('readerBookmarkOnPage（当前页有没有书签）', () {
    const ReaderBookmarkPageRange page = (
      section: 2,
      charStart: 100,
      charEnd: 180,
      chapterCharCount: 1000,
    );

    test('精确偏移：同章且落在 [start, end) 内才算', () {
      final Bookmark inside = _bm(charOffset: 100);
      expect(readerBookmarkOnPage(<Bookmark>[inside], page), inside);
      expect(
        readerBookmarkOnPage(<Bookmark>[_bm(charOffset: 179)], page),
        isNotNull,
      );
      // 右开：下一页页首不算本页。
      expect(
        readerBookmarkOnPage(<Bookmark>[_bm(charOffset: 180)], page),
        isNull,
      );
      expect(
        readerBookmarkOnPage(<Bookmark>[_bm(charOffset: 99)], page),
        isNull,
      );
      // 别的章同偏移不算。
      expect(
        readerBookmarkOnPage(<Bookmark>[
          _bm(section: 3, charOffset: 120),
        ], page),
        isNull,
      );
    });

    test('旧书签（charOffset -1）一律不算在当前页（分数折算可能落邻页，误判会删别页书签）', () {
      // 1200/10000 × 1000 = 120 虽然落在 [100,180)，也不判。
      expect(
        readerBookmarkOnPage(<Bookmark>[_bm(normCharOffset: 1200)], page),
        isNull,
      );
      // 同页有精确书签时照样认出精确那条。
      final Bookmark precise = _bm(charOffset: 150);
      expect(
        readerBookmarkOnPage(<Bookmark>[
          _bm(normCharOffset: 1200),
          precise,
        ], page),
        same(precise),
      );
    });

    test('shell 没给终点（-1）按单点处理；区间未知 / 起点无效时不判', () {
      const ReaderBookmarkPageRange point = (
        section: 2,
        charStart: 100,
        charEnd: -1,
        chapterCharCount: 1000,
      );
      expect(
        readerBookmarkOnPage(<Bookmark>[_bm(charOffset: 100)], point),
        isNotNull,
      );
      expect(
        readerBookmarkOnPage(<Bookmark>[_bm(charOffset: 101)], point),
        isNull,
      );
      expect(
        readerBookmarkOnPage(<Bookmark>[_bm(charOffset: 100)], null),
        isNull,
      );
      expect(
        readerBookmarkOnPage(
          <Bookmark>[_bm(charOffset: 0)],
          (section: 2, charStart: -1, charEnd: 50, chapterCharCount: 1000),
        ),
        isNull,
      );
    });
  });

  group('readerBookmarkJumpFor（跳转参数）', () {
    test('有精确偏移走字符锚', () {
      final ReaderBookmarkJump jump = readerBookmarkJumpFor(
        _bm(section: 4, normCharOffset: 5000, charOffset: 321),
      );
      expect(jump.section, 4);
      expect(jump.charOffset, 321);
      expect(jump.progress, 0.0);
    });

    test('旧书签按分数 /10000，并夹在 [0,1]', () {
      final ReaderBookmarkJump jump = readerBookmarkJumpFor(
        _bm(section: 1, normCharOffset: 2500),
      );
      expect(jump.section, 1);
      expect(jump.charOffset, -1);
      expect(jump.progress, closeTo(0.25, 1e-9));
      expect(readerBookmarkJumpFor(_bm(normCharOffset: 12000)).progress, 1.0);
    });
  });

  test('readerBookmarksNewestFirst 按创建时间倒序、不改入参', () {
    final Bookmark a = _bm(id: 1, createdAt: DateTime(2026, 1, 1));
    final Bookmark b = _bm(id: 2, createdAt: DateTime(2026, 3, 1));
    final Bookmark c = _bm(id: 3, createdAt: DateTime(2026, 2, 1));
    final List<Bookmark> input = <Bookmark>[a, b, c];
    expect(readerBookmarksNewestFirst(input), <Bookmark>[b, c, a]);
    expect(input, <Bookmark>[a, b, c]);
  });
}
