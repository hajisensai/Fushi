import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/library/online_manga_chapter_updates.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';

/// v101 漫画新章判据：diff 就在刷新手里，不需要「已见章节」表。
void main() {
  OnlineMangaChapter chapter(String key, {String name = '', double? number}) =>
      OnlineMangaChapter(
        key: key,
        name: name,
        raw: const <String, Object?>{},
        number: number,
      );

  test('只报新出现的章', () {
    final List<OnlineMangaChapter> fresh = newlyAppearedChapters(
      previous: <OnlineMangaChapter>[chapter('c1'), chapter('c2')],
      current: <OnlineMangaChapter>[
        chapter('c1'),
        chapter('c2'),
        chapter('c3'),
        chapter('c4'),
      ],
    );
    expect(fresh.map((OnlineMangaChapter c) => c.key), <String>['c3', 'c4']);
  });

  test('首次入库不报：整本都是「新」的，但那是用户自己刚点的加入书架', () {
    expect(
      newlyAppearedChapters(
        previous: const <OnlineMangaChapter>[],
        current: <OnlineMangaChapter>[chapter('c1'), chapter('c2')],
      ),
      isEmpty,
    );
  });

  test('两侧完全无交集不报：那是源换了 key 编法，不是更新了 200 章', () {
    expect(
      newlyAppearedChapters(
        previous: <OnlineMangaChapter>[chapter('old/1'), chapter('old/2')],
        current: <OnlineMangaChapter>[chapter('new/1'), chapter('new/2')],
      ),
      isEmpty,
    );
  });

  test('章节列表空（Cloudflare 拦截页的形状）不报', () {
    expect(
      newlyAppearedChapters(
        previous: <OnlineMangaChapter>[chapter('c1')],
        current: const <OnlineMangaChapter>[],
      ),
      isEmpty,
    );
  });

  test('显示名：有名用名，无名退回章号，整数章号不带小数点', () {
    expect(mangaChapterDisplayName(chapter('c1', name: '第 12 话')), '第 12 话');
    expect(mangaChapterDisplayName(chapter('c1', number: 12)), '12');
    expect(mangaChapterDisplayName(chapter('c1', number: 12.5)), '12.5');
    expect(mangaChapterDisplayName(chapter('c1')), '');
  });
}
