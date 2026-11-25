import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/library/manga_tracking_progress.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';

OnlineMangaChapter _chapter(String key, double? number) => OnlineMangaChapter(
  key: key,
  name: key,
  number: number,
  raw: const <String, Object?>{},
);

void main() {
  test('highest read chapter number, decimals floored', () {
    final MangaReadProgress progress = mangaReadProgressFrom(
      chapters: <OnlineMangaChapter>[
        _chapter('c13', 13),
        _chapter('c12.5', 12.5),
        _chapter('c12', 12),
        _chapter('c1', 1),
      ],
      readAtByKey: <String, int>{'c12.5': 30, 'c12': 20, 'c1': 10},
    );
    expect(progress.highestChapter, 12);
    expect(progress.allRead, isFalse);
    expect(progress.lastReadAt, 30);
  });

  test('chapters without a usable number never count', () {
    final MangaReadProgress progress = mangaReadProgressFrom(
      chapters: <OnlineMangaChapter>[
        _chapter('special', null),
        _chapter('unknown', 0),
        _chapter('bad', -1),
      ],
      readAtByKey: <String, int>{'special': 1, 'unknown': 2, 'bad': 3},
    );
    expect(progress.highestChapter, isNull);
    expect(progress.allRead, isTrue);
  });

  test('all read needs every chapter, and at least one', () {
    expect(
      mangaReadProgressFrom(
        chapters: <OnlineMangaChapter>[_chapter('a', 1), _chapter('b', 2)],
        readAtByKey: <String, int>{'a': 1, 'b': 2},
      ).allRead,
      isTrue,
    );
    expect(
      mangaReadProgressFrom(
        chapters: const <OnlineMangaChapter>[],
        readAtByKey: const <String, int>{},
      ).allRead,
      isFalse,
    );
  });
}
