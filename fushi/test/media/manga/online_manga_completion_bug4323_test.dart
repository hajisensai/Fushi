import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/library/manga_adjacent_chapter.dart';
import 'package:fushi/src/media/manga/library/manga_resume_point.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi_core/fushi_core.dart';

import '../../helpers/source_guard.dart';

/// BUG-4355（反馈 8VgLlmIezE）：在线漫画读完任意一章末页整本被标「读完」；
/// 「标记此章及更早为已读」不影响书架进度。
///
/// ① 整本 completedAt 只在读完阅读顺序上的最后一话时写（[mangaChapterCompletesSeries]）；
/// ② 书架进度按章 readAt 算（[onlineMangaShelfProgress]），标记已读即变；
/// ③ 书架订阅章已读集合（`watchMangaChapterReadKeys`），标记后即时重算。
OnlineMangaChapter _chapter(String key, {double? number, String? scanlator}) =>
    OnlineMangaChapter(
      key: key,
      name: key,
      number: number,
      scanlator: scanlator,
      raw: const <String, Object?>{},
    );

OnlineMangaLibraryEntry _entry(
  List<OnlineMangaChapter> chapters, {
  int? currentChapterIndex,
}) => OnlineMangaLibraryEntry(
  runtime: OnlineMangaRuntimeKind.mihon,
  extensionPackage: 'org.example',
  sourceId: '1',
  series: const OnlineMangaSeries(
    key: '/s',
    title: 'Fixture',
    raw: <String, Object?>{},
  ),
  chapters: chapters,
  currentChapterIndex: currentChapterIndex,
);

void main() {
  // 源顺序新→旧：下标 0 = 第 4 话（最新 / 阅读顺序上最后一话）。
  final List<OnlineMangaChapter> chapters = <OnlineMangaChapter>[
    _chapter('/c/4', number: 4),
    _chapter('/c/3', number: 3),
    _chapter('/c/2', number: 2),
    _chapter('/c/1', number: 1),
  ];

  group('mangaChapterCompletesSeries（整本读完判据）', () {
    test('读完非最后一话不算读完整本', () {
      for (final int index in <int>[1, 2, 3]) {
        expect(
          mangaChapterCompletesSeries(chapters: chapters, chapterIndex: index),
          isFalse,
          reason: '下标 $index 之后还有更新的一话',
        );
      }
    });

    test('读完最后一话（列表新→旧的下标 0）算读完整本', () {
      expect(
        mangaChapterCompletesSeries(chapters: chapters, chapterIndex: 0),
        isTrue,
      );
    });

    test('最新一话的另一个汉化版本同样算读完整本（与阅读器 skipDuplicate 同口径）', () {
      final List<OnlineMangaChapter> versions = <OnlineMangaChapter>[
        _chapter('/c/4a', number: 4, scanlator: 'A'),
        _chapter('/c/4b', number: 4, scanlator: 'B'),
        _chapter('/c/3', number: 3),
      ];
      expect(
        mangaChapterCompletesSeries(chapters: versions, chapterIndex: 1),
        isTrue,
      );
      expect(
        mangaChapterCompletesSeries(chapters: versions, chapterIndex: 2),
        isFalse,
      );
    });

    test('越界 / 空列表不算读完', () {
      expect(
        mangaChapterCompletesSeries(chapters: chapters, chapterIndex: -1),
        isFalse,
      );
      expect(
        mangaChapterCompletesSeries(chapters: chapters, chapterIndex: 4),
        isFalse,
      );
      expect(
        mangaChapterCompletesSeries(
          chapters: const <OnlineMangaChapter>[],
          chapterIndex: 0,
        ),
        isFalse,
      );
    });

    test('阅读器写整本 completedAt 必须经过该判据（源码守卫）', () {
      final String src = compactCode(
        File(
          'lib/src/media/manga/reader/manga_fushi_page.dart',
        ).readAsStringSync(),
      );
      final int call = src.indexOf('markEpubBookCompletedIfUnset(');
      expect(call, greaterThan(0));
      // 写 completedAt 的那个分支之前（同一个 _persistPosition 收口里）必须由
      // mangaChapterCompletesSeries 把关，不能再只凭当前载荷的末页。
      final int gate = src.lastIndexOf('mangaChapterCompletesSeries(', call);
      final int persist = src.lastIndexOf('_persistPosition(', call);
      expect(gate, greaterThan(persist));
      expect(
        'markEpubBookCompletedIfUnset('.allMatches(src).length,
        1,
        reason: '漫画阅读器只应有一个整本读完的写入点',
      );
    });
  });

  group('onlineMangaShelfProgress（书架进度按章 readAt）', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    double fraction(({int position, int duration}) p) =>
        p.position / p.duration;

    test('打开过最新一话（下标 0）不再等于全部读完', () async {
      final OnlineMangaLibraryEntry entry = _entry(
        chapters,
        currentChapterIndex: 0,
      );
      final ({int position, int duration}) p = onlineMangaShelfProgress(
        entry,
        await db.getMangaChapterStates('u'),
      );
      expect(p.position, greaterThan(0), reason: '打开过 = 在读');
      expect(p.position, lessThan(p.duration ~/ 4), reason: '一话都没读完');
    });

    test('标记章节已读后进度变化（标记此章及更早 = 下标 1..3）', () async {
      final OnlineMangaLibraryEntry entry = _entry(chapters);
      final ({int position, int duration}) before = onlineMangaShelfProgress(
        entry,
        await db.getMangaChapterStates('u'),
      );
      expect(before.position, 0, reason: '没选过章、没标过已读 = 未读');

      await db.markMangaChaptersRead(
        bookUid: 'u',
        chapterKeys: <String>['/c/3', '/c/2', '/c/1'],
      );
      final ({int position, int duration}) after = onlineMangaShelfProgress(
        entry,
        await db.getMangaChapterStates('u'),
      );
      expect(fraction(after), closeTo(0.75, 1e-9));
      expect(after.position, lessThan(after.duration), reason: '最后一话还没读');

      await db.markMangaChaptersRead(
        bookUid: 'u',
        chapterKeys: <String>['/c/4'],
      );
      final ({int position, int duration}) all = onlineMangaShelfProgress(
        entry,
        await db.getMangaChapterStates('u'),
      );
      expect(all.position, all.duration);

      await db.clearMangaChaptersRead(
        bookUid: 'u',
        chapterKeys: <String>['/c/4', '/c/3'],
      );
      final ({int position, int duration}) cleared = onlineMangaShelfProgress(
        entry,
        await db.getMangaChapterStates('u'),
      );
      expect(fraction(cleared), closeTo(0.5, 1e-9));
    });

    test('当前章未读完按章内页数折算、绝不凑成一整章', () async {
      final OnlineMangaLibraryEntry entry = _entry(
        chapters,
        currentChapterIndex: 2,
      );
      await db.markMangaChaptersRead(
        bookUid: 'u',
        chapterKeys: <String>['/c/1'],
      );
      await db.saveMangaChapterState(
        bookUid: 'u',
        chapterKey: '/c/2',
        lastPage: 9,
        pageCount: 20,
      );
      final ({int position, int duration}) half = onlineMangaShelfProgress(
        entry,
        await db.getMangaChapterStates('u'),
      );
      expect(half.duration, 4 * kMangaShelfUnitsPerChapter);
      expect(
        half.position,
        kMangaShelfUnitsPerChapter + kMangaShelfUnitsPerChapter ~/ 2,
      );

      // 停在末页但还没写 readAt：仍封顶在不足一整章。
      await db.saveMangaChapterState(
        bookUid: 'u',
        chapterKey: '/c/2',
        lastPage: 19,
        pageCount: 20,
      );
      final ({int position, int duration}) end = onlineMangaShelfProgress(
        entry,
        await db.getMangaChapterStates('u'),
      );
      expect(end.position, 2 * kMangaShelfUnitsPerChapter - 1);

      // 读完（readAt 写上）：计为整章，不再叠加章内进度。
      await db.saveMangaChapterState(
        bookUid: 'u',
        chapterKey: '/c/2',
        lastPage: 19,
        pageCount: 20,
        readAt: 1,
      );
      final ({int position, int duration}) done = onlineMangaShelfProgress(
        entry,
        await db.getMangaChapterStates('u'),
      );
      expect(done.position, 2 * kMangaShelfUnitsPerChapter);
    });

    test('不在章节列表里的旧章 key 不计入', () async {
      await db.markMangaChaptersRead(
        bookUid: 'u',
        chapterKeys: <String>['/c/gone', '/c/1'],
      );
      final ({int position, int duration}) p = onlineMangaShelfProgress(
        _entry(chapters),
        await db.getMangaChapterStates('u'),
      );
      expect(p.position, kMangaShelfUnitsPerChapter);
    });

    test('空章节列表 = 未读', () {
      final ({int position, int duration}) p = onlineMangaShelfProgress(
        _entry(const <OnlineMangaChapter>[], currentChapterIndex: 0),
        const <String, MangaChapterStateRow>{},
      );
      expect(p.position, 0);
      expect(p.duration, 1);
    });
  });

  group('书架刷新路径', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('getAllMangaChapterStatesByBook 按书分组', () async {
      await db.markMangaChaptersRead(
        bookUid: 'a',
        chapterKeys: <String>['/c/1', '/c/2'],
      );
      await db.saveMangaChapterState(
        bookUid: 'b',
        chapterKey: '/c/9',
        lastPage: 3,
      );
      final Map<String, Map<String, MangaChapterStateRow>> all = await db
          .getAllMangaChapterStatesByBook();
      expect(all.keys.toSet(), <String>{'a', 'b'});
      expect(all['a']!.keys.toSet(), <String>{'/c/1', '/c/2'});
      expect(all['b']!['/c/9']!.readAt, isNull);
    });

    test('watchMangaChapterReadKeys 随标记已读 / 未读变化', () async {
      final List<List<String>> seen = <List<String>>[];
      final StreamSubscription<List<String>> sub = db
          .watchMangaChapterReadKeys()
          .listen(seen.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();
      expect(seen.last, isEmpty);

      await db.markMangaChaptersRead(
        bookUid: 'u',
        chapterKeys: <String>['/c/1'],
      );
      await pumpEventQueue();
      expect(seen.last, <String>['u\u0000/c/1']);

      // 翻页只写 lastPage：已读集合不变。
      await db.saveMangaChapterState(
        bookUid: 'u',
        chapterKey: '/c/2',
        lastPage: 5,
      );
      await pumpEventQueue();
      expect(seen.last, <String>['u\u0000/c/1']);

      await db.clearMangaChaptersRead(
        bookUid: 'u',
        chapterKeys: <String>['/c/1'],
      );
      await pumpEventQueue();
      expect(seen.last, isEmpty);
    });

    test('fushiBooksProvider 订阅章已读集合（源码守卫）', () {
      final String src = File(
        'lib/src/media/sources/reader_fushi_source.dart',
      ).readAsStringSync();
      expect(src.contains('watchMangaChapterReadKeys()'), isTrue);
      expect(src.contains('ref.watch(_mangaChapterReadKeysProvider)'), isTrue);
      expect(src.contains('onlineMangaShelfProgress('), isTrue);
    });
  });
}
