import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/library/manga_adjacent_chapter.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';

import '../../helpers/source_guard.dart';

OnlineMangaChapter _chapter(String key, {double? number, String? scanlator}) =>
    OnlineMangaChapter(
      key: key,
      name: key,
      number: number,
      scanlator: scanlator,
      raw: const <String, Object?>{},
    );

void main() {
  // 源顺序是新→旧：下标 0 = 最新一话。
  final List<OnlineMangaChapter> plain = <OnlineMangaChapter>[
    _chapter('c4', number: 4),
    _chapter('c3', number: 3),
    _chapter('c2', number: 2),
    _chapter('c1', number: 1),
  ];

  group('resolveAdjacentMangaChapter', () {
    test(
      'forward walks toward the newer end (index - 1), backward the other',
      () {
        expect(
          resolveAdjacentMangaChapter(
            chapters: plain,
            currentIndex: 2,
            forward: true,
          ),
          1,
        );
        expect(
          resolveAdjacentMangaChapter(
            chapters: plain,
            currentIndex: 2,
            forward: false,
          ),
          3,
        );
      },
    );

    test('returns null at either end and for an out-of-range index', () {
      expect(
        resolveAdjacentMangaChapter(
          chapters: plain,
          currentIndex: 0,
          forward: true,
        ),
        isNull,
      );
      expect(
        resolveAdjacentMangaChapter(
          chapters: plain,
          currentIndex: 3,
          forward: false,
        ),
        isNull,
      );
      expect(
        resolveAdjacentMangaChapter(
          chapters: plain,
          currentIndex: -1,
          forward: true,
        ),
        isNull,
      );
    });

    test('skipRead skips read chapters only when enabled', () {
      const Set<String> read = <String>{'c2', 'c3'};
      expect(
        resolveAdjacentMangaChapter(
          chapters: plain,
          currentIndex: 3,
          forward: true,
          readChapterKeys: read,
        ),
        2,
        reason: 'the switch is off: read chapters stay reachable',
      );
      expect(
        resolveAdjacentMangaChapter(
          chapters: plain,
          currentIndex: 3,
          forward: true,
          readChapterKeys: read,
          skipRead: true,
        ),
        0,
      );
      expect(
        resolveAdjacentMangaChapter(
          chapters: plain,
          currentIndex: 1,
          forward: false,
          readChapterKeys: const <String>{'c2', 'c1'},
          skipRead: true,
        ),
        isNull,
        reason: 'everything before is read: there is nowhere to go',
      );
    });

    test('skipRead never filters the current chapter itself', () {
      expect(
        resolveAdjacentMangaChapter(
          chapters: plain,
          currentIndex: 2,
          forward: true,
          readChapterKeys: const <String>{'c2'},
          skipRead: true,
        ),
        1,
      );
    });

    group('skipDuplicate', () {
      // 第 2 话有两个汉化组版本，第 3 话也有两个。
      final List<OnlineMangaChapter> dupes = <OnlineMangaChapter>[
        _chapter('c3-b', number: 3, scanlator: 'B'),
        _chapter('c3-a', number: 3, scanlator: 'A'),
        _chapter('c2-b', number: 2, scanlator: 'B'),
        _chapter('c2-a', number: 2, scanlator: 'A'),
        _chapter('c1-a', number: 1, scanlator: 'A'),
      ];

      test('off: the other version of the same number is the next chapter', () {
        expect(
          resolveAdjacentMangaChapter(
            chapters: dupes,
            currentIndex: 3,
            forward: true,
          ),
          2,
        );
      });

      test('on: skips same-number chapters and prefers the same scanlator', () {
        expect(
          resolveAdjacentMangaChapter(
            chapters: dupes,
            currentIndex: 3,
            forward: true,
            skipDuplicate: true,
          ),
          1,
          reason: 'c2-b is a duplicate of c2-a; c3-a matches scanlator A',
        );
        expect(
          resolveAdjacentMangaChapter(
            chapters: dupes,
            currentIndex: 2,
            forward: true,
            skipDuplicate: true,
          ),
          0,
          reason: 'reading B: the B version of chapter 3 wins',
        );
        expect(
          resolveAdjacentMangaChapter(
            chapters: dupes,
            currentIndex: 2,
            forward: false,
            skipDuplicate: true,
          ),
          4,
          reason: 'no B version of chapter 1: take the first one met',
        );
      });

      test('same-scanlator preference respects skipRead', () {
        expect(
          resolveAdjacentMangaChapter(
            chapters: dupes,
            currentIndex: 3,
            forward: true,
            skipDuplicate: true,
            skipRead: true,
            readChapterKeys: const <String>{'c3-a'},
          ),
          0,
        );
      });

      test('unknown chapter numbers never count as duplicates', () {
        final List<OnlineMangaChapter> unknown = <OnlineMangaChapter>[
          _chapter('extra'),
          _chapter('neg', number: -1),
          _chapter('cur'),
        ];
        expect(
          resolveAdjacentMangaChapter(
            chapters: unknown,
            currentIndex: 2,
            forward: true,
            skipDuplicate: true,
          ),
          1,
        );
      });
    });
  });

  group('shouldPrefetchNextMangaChapter', () {
    test('short chapters prefetch immediately', () {
      expect(
        shouldPrefetchNextMangaChapter(currentPage: 0, pageCount: 1),
        isTrue,
      );
      expect(
        shouldPrefetchNextMangaChapter(
          currentPage: 0,
          pageCount: kMangaShortChapterPageCount,
        ),
        isTrue,
      );
    });

    test('long chapters wait for the last third', () {
      expect(
        shouldPrefetchNextMangaChapter(currentPage: 0, pageCount: 30),
        isFalse,
      );
      expect(
        shouldPrefetchNextMangaChapter(currentPage: 18, pageCount: 30),
        isFalse,
      );
      expect(
        shouldPrefetchNextMangaChapter(currentPage: 19, pageCount: 30),
        isTrue,
      );
      expect(
        shouldPrefetchNextMangaChapter(currentPage: 29, pageCount: 30),
        isTrue,
      );
    });

    test('nothing loaded means no prefetch', () {
      expect(
        shouldPrefetchNextMangaChapter(currentPage: 0, pageCount: 0),
        isFalse,
      );
    });
  });

  // 换章与预下载都住在 MangaFushiPage 的私有 State 方法里，行为测试够不到，
  // 在源码层钉住接线：两者必须经过上面的纯函数，不得退回 `index ± 1`。
  group('MangaFushiPage wiring', () {
    final String source = maskComments(
      File(
        'lib/src/media/manga/reader/manga_fushi_page.dart',
      ).readAsStringSync(),
    );

    test('chapter edge resolves its target through the skip rules', () {
      final String edge = methodBody(
        source,
        'Future<void> _onReachedChapterEdge(int delta) async {',
      );
      expect(edge, contains('_adjacentChapterIndex(forward: forward)'));
      expect(edge, isNot(contains('_shelfChapterIndex +')));
      final String adjacent = methodBody(
        source,
        'Future<int?> _adjacentChapterIndex({required bool forward}) async {',
      );
      expect(adjacent, contains('resolveAdjacentMangaChapter('));
      expect(adjacent, contains('skipRead: prefs.skipRead'));
      expect(adjacent, contains('skipDuplicate: prefs.skipDuplicate'));
    });

    test('progress recording drives the next-chapter prefetch', () {
      final String record = methodBody(source, 'void _recordProgress() {');
      expect(record, contains('_maybePrefetchNextChapter()'));
      final String prefetch = methodBody(
        source,
        'Future<void> _maybePrefetchNextChapter() async {',
      );
      expect(prefetch, contains('_readerPreferences.downloadAhead'));
      expect(prefetch, contains('shouldPrefetchNextMangaChapter('));
      expect(prefetch, contains('_adjacentChapterIndex(forward: true)'));
      expect(prefetch, contains('_prefetchCheckedChapterKeys'));
      expect(prefetch, contains('enqueueChapter('));
    });
  });
}
