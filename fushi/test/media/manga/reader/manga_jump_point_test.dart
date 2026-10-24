import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/reader/manga_jump_point.dart';
import 'package:fushi/src/utils/misc/jump_history.dart';

void main() {
  group('MangaJumpPoint.isSamePlace', () {
    test('same chapter + page ignores the in-page fraction', () {
      expect(
        MangaJumpPoint.isSamePlace(
          const MangaJumpPoint(chapterKey: 'c1', page: 3, pageCount: 20),
          const MangaJumpPoint(
            chapterKey: 'c1',
            page: 3,
            pageCount: 20,
            fraction: 0.5,
          ),
        ),
        isTrue,
      );
    });

    test('different chapter or page is a different place', () {
      const MangaJumpPoint a = MangaJumpPoint(
        chapterKey: 'c1',
        page: 3,
        pageCount: 20,
      );
      expect(
        MangaJumpPoint.isSamePlace(
          a,
          const MangaJumpPoint(chapterKey: 'c2', page: 3, pageCount: 20),
        ),
        isFalse,
      );
      expect(
        MangaJumpPoint.isSamePlace(
          a,
          const MangaJumpPoint(chapterKey: 'c1', page: 4, pageCount: 20),
        ),
        isFalse,
      );
    });

    test('drives JumpHistory back / forward across chapters', () {
      final JumpHistory<MangaJumpPoint> history = JumpHistory<MangaJumpPoint>(
        isSamePlace: MangaJumpPoint.isSamePlace,
      );
      const MangaJumpPoint origin = MangaJumpPoint(
        chapterKey: 'c3',
        page: 11,
        pageCount: 30,
        fraction: 0.25,
      );
      const MangaJumpPoint landed = MangaJumpPoint(
        chapterKey: 'c7',
        page: 0,
        pageCount: 18,
      );
      expect(history.recordDeparture(origin), isTrue);
      // Re-recording the same page (tapping the same entry twice) is a no-op.
      expect(history.recordDeparture(origin), isFalse);
      expect(history.goBack(landed), same(origin));
      expect(history.forwardTarget, same(landed));
      expect(history.goForward(origin), same(landed));
      expect(history.backTarget, same(origin));
    });
  });

  group('mangaJumpPointLabel', () {
    test('same chapter / local volume shows only the page', () {
      expect(
        mangaJumpPointLabel(
          point: const MangaJumpPoint(
            chapterKey: 'c1',
            page: 11,
            pageCount: 40,
          ),
          currentChapterKey: 'c1',
          chapterName: '第3話',
        ),
        '12 / 40',
      );
      expect(
        mangaJumpPointLabel(
          point: const MangaJumpPoint(chapterKey: null, page: 0, pageCount: 5),
          currentChapterKey: null,
          chapterName: null,
        ),
        '1 / 5',
      );
    });

    test('other chapter prefixes the chapter name', () {
      expect(
        mangaJumpPointLabel(
          point: const MangaJumpPoint(
            chapterKey: 'c3',
            page: 11,
            pageCount: 40,
          ),
          currentChapterKey: 'c9',
          chapterName: '第3話',
        ),
        '第3話 · 12 / 40',
      );
    });

    test('unknown page count / empty name degrade gracefully', () {
      expect(
        mangaJumpPointLabel(
          point: const MangaJumpPoint(chapterKey: 'c3', page: 0, pageCount: 0),
          currentChapterKey: 'c9',
          chapterName: '  ',
        ),
        '1',
      );
    });

    test('long chapter names are truncated', () {
      expect(
        mangaJumpPointLabel(
          point: const MangaJumpPoint(chapterKey: 'c3', page: 1, pageCount: 9),
          currentChapterKey: 'c9',
          chapterName: 'あ' * 30,
        ),
        '${'あ' * kMangaJumpLabelChapterMaxChars}… · 2 / 9',
      );
    });
  });
}
