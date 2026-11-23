import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/book_continue.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/manga_fushi_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/pages/implementations/home_nav_peek.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart'
    show filterShelfEntriesByMangaSplit;
import 'package:fushi_core/fushi_core.dart' show MediaCollectionRow;

/// BUG-5332：侧栏书 / 漫画速览、书架 / 漫画库顶部「继续阅读」与首页「继续」区
/// 各有一套选书，同一时刻给出三个答案。三处现在都只经
/// [selectMediaItemContinueCandidates]；这里钉住它的口径与速览编排。
MediaItem _book(
  String key, {
  int position = 0,
  int duration = 100,
  bool manga = false,
}) => MediaItem(
  mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(key),
  title: key,
  mediaTypeIdentifier: ReaderFushiSource.instance.mediaType.uniqueKey,
  mediaSourceIdentifier: manga
      ? MangaFushiSource.kUniqueKey
      : ReaderFushiSource.instance.uniqueKey,
  position: position,
  duration: duration,
  canDelete: false,
  canEdit: true,
);

MediaCollectionRow _collection(int id, String name) => MediaCollectionRow(
  origin: 'user',
  organizeAliases: '',
  id: id,
  name: name,
  collectionType: 'collection',
  sortOrder: 0,
  coverSource: null,
  createdAt: 0,
  orderUpdatedAt: 0,
);

/// 一个书架快照：书、最近阅读时刻（键 = bookKey，测试里 uid 就是 bookKey）、
/// 读完集合、合集归属（bookKey → (合集 id, sortIndex)）。
class _Shelf {
  _Shelf({
    required this.books,
    this.readAt = const <String, int>{},
    this.completed = const <String>{},
    this.membership = const <String, (int, int)>{},
    this.collections = const <int, String>{7: 'ダンジョンマスター'},
  });

  final List<MediaItem> books;
  final Map<String, int> readAt;
  final Set<String> completed;
  final Map<String, (int, int)> membership;
  final Map<int, String> collections;

  Map<String, int> get primary => <String, int>{
    for (final MapEntry<String, (int, int)> e in membership.entries)
      'epub|${e.key}': e.value.$1,
  };

  Map<int, MediaCollectionRow> get collectionsById => <int, MediaCollectionRow>{
    for (final MapEntry<int, String> e in collections.entries)
      e.key: _collection(e.key, e.value),
  };

  List<BookContinueCandidate<MediaItem>> select({List<MediaItem>? from}) =>
      selectMediaItemContinueCandidates(
        books: from ?? books,
        lastReadAtByUid: readAt,
        epubUidByKey: const <String, String>{},
        completedBookKeys: completed,
        primaryCollectionIdByEntry: primary,
        collectionIds: collections.keys.toSet(),
        memberSortIndex: <String, int>{
          for (final MapEntry<String, (int, int)> e in membership.entries)
            'epub|${e.key}': e.value.$2,
        },
      );

  /// 速览编排：与 `_loadBooks` 同样喂候选 + 最近读过的书（时刻倒序）。
  ({
    BookContinueCandidate<MediaItem>? resume,
    List<BookNavPeekItem<MediaItem>> recent,
  })
  peek({List<MediaItem>? from}) {
    final List<MediaItem> pool = from ?? books;
    int recentOf(MediaItem m) => readAt[_key(m)] ?? 0;
    return planBookNavPeek<MediaItem>(
      candidates: select(from: pool),
      recentlyRead: pool.where((MediaItem m) => recentOf(m) > 0).toList()
        ..sort((MediaItem a, MediaItem b) => recentOf(b) - recentOf(a)),
      compositeKeyOf: (MediaItem m) => bookCollectionEntryKey(
        m,
        epubUidByKey: const <String, String>{},
        primaryCollectionIdByEntry: primary,
      ),
      primaryCollectionIdByEntry: primary,
      collectionsById: collectionsById,
    );
  }
}

String _key(MediaItem m) => ReaderFushiSource.parseBookKey(m.mediaIdentifier)!;

List<String> _keys(Iterable<BookContinueCandidate<MediaItem>> cs) => <String>[
  for (final BookContinueCandidate<MediaItem> c in cs) _key(c.item),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('G1 合集 Next-Up', () {
    // 用户形态：读完第 1 卷（标了读完），第 2、3 卷没开读。
    _Shelf shelf() => _Shelf(
      books: <MediaItem>[
        _book('dm3'),
        _book('dm1', position: 99, duration: 100),
        _book('dm2'),
      ],
      readAt: <String, int>{'dm1': 100},
      completed: <String>{'dm1'},
      membership: <String, (int, int)>{
        'dm1': (7, 0),
        'dm2': (7, 1),
        'dm3': (7, 2),
      },
    );

    test('读完第 1 卷 → 候选是第 2 卷（不是消失、也不是读完的第 1 卷）', () {
      final List<BookContinueCandidate<MediaItem>> cs = shelf().select();
      expect(_keys(cs), <String>['dm2']);
      final BookContinueCandidate<MediaItem> c = cs.single;
      expect(c.collectionId, 7);
      expect(c.memberOrdinal, 2);
      expect(c.recentMs, 100, reason: '单元时刻 = 组内最近阅读（含读完的卷）');
      expect(
        <String>[for (final MediaItem m in c.members) _key(m)],
        <String>['dm1', 'dm2', 'dm3'],
      );
    });

    test('速览「继续」与书架 hero 是同一项：第 2 卷；「最近」不再出现读完的第 1 卷', () {
      final _Shelf s = shelf();
      final ({
        BookContinueCandidate<MediaItem>? resume,
        List<BookNavPeekItem<MediaItem>> recent,
      })
      plan = s.peek();
      // 书架 hero（`_pickShelfContinue`）= 候选第一项。
      final MediaItem hero = s.select().first.item;
      expect(plan.resume, isNotNull);
      expect(identical(plan.resume!.item, hero), isTrue);
      expect(_key(plan.resume!.item), 'dm2');
      expect(plan.recent, isEmpty, reason: '合集已由继续项覆盖，不再以第 1 卷重复出现');
    });

    test('G10 速览副行与首页徽标同一卷号：「Vol. 2」', () {
      final BookContinueCandidate<MediaItem> c = shelf().select().single;
      expect(
        bookNavPeekSeriesCue(c, collectionName: 'ダンジョンマスター'),
        t.home_continue_volume(n: 2),
      );
      expect(c.volumeNumber(bookContinueDisplayTitle), 2);
    });
  });

  test('G2 最新读的那卷读完、更早一卷读到一半：按 Next-Up 锚在最近读的那卷', () {
    final _Shelf s = _Shelf(
      books: <MediaItem>[
        _book('v1', position: 40),
        _book('v2', position: 100),
        _book('v3'),
      ],
      readAt: <String, int>{'v1': 50, 'v2': 100},
      membership: <String, (int, int)>{
        'v1': (7, 0),
        'v2': (7, 1),
        'v3': (7, 2),
      },
    );
    expect(_keys(s.select()), <String>['v3']);
    expect(_key(s.peek().resume!.item), 'v3');

    // 最近读完的就是最后一卷：整套按读完处理，不再出候选；速览「最近」给这套书
    // 最近读的那卷（与库页、首页同一结论，不再各说各的）。
    final _Shelf done = _Shelf(
      books: <MediaItem>[_book('v1', position: 40), _book('v2', position: 100)],
      readAt: <String, int>{'v1': 50, 'v2': 100},
      membership: <String, (int, int)>{'v1': (7, 0), 'v2': (7, 1)},
    );
    expect(done.select(), isEmpty);
    final ({
      BookContinueCandidate<MediaItem>? resume,
      List<BookNavPeekItem<MediaItem>> recent,
    })
    plan = done.peek();
    expect(plan.resume, isNull);
    expect(plan.recent.single.read!.collectionId, 7);
    expect(_key(plan.recent.single.read!.item), 'v2');
  });

  group('G5 在线漫画只靠章已读', () {
    test('章 readAt 并进最近阅读时刻（取大），位置表没有行也算读过', () {
      final Map<String, int> merged = mergeMangaChapterReadRecency(
        readerPositionUpdatedAt: <String, int>{'epubA': 300, 'manga': 10},
        chapterStates: <({String bookUid, int? readAt})>[
          (bookUid: 'online', readAt: 200),
          (bookUid: 'online', readAt: 250),
          (bookUid: 'online', readAt: null),
          (bookUid: 'manga', readAt: 40),
          (bookUid: 'epubA', readAt: 100),
        ],
      );
      expect(merged, <String, int>{'epubA': 300, 'manga': 40, 'online': 250});
    });

    test('标记已读的在线漫画进速览「继续」，与库页 hero 同一本', () {
      final MediaItem online = _book(
        'online',
        position: 300,
        duration: 1000,
        manga: true,
      );
      final _Shelf s = _Shelf(
        books: <MediaItem>[online],
        readAt: mergeMangaChapterReadRecency(
          readerPositionUpdatedAt: const <String, int>{},
          chapterStates: <({String bookUid, int? readAt})>[
            (bookUid: 'online', readAt: 500),
          ],
        ),
      );
      expect(s.select().single.recentMs, 500);
      expect(identical(s.peek().resume!.item, online), isTrue);
    });

    test('在读但完全没有时刻的散书仍是候选（库页与首页一直收它）', () {
      final _Shelf s = _Shelf(books: <MediaItem>[_book('a', position: 5)]);
      expect(_keys(s.select()), <String>['a']);
      expect(_key(s.peek().resume!.item), 'a');
    });
  });

  test('读完判据：completedAt 优先于进度；整套读完 / 一卷没开读的合集不出候选', () {
    final _Shelf s = _Shelf(
      books: <MediaItem>[
        _book('marked', position: 99),
        _book('atEnd', position: 100),
        _book('fresh'),
        _book('reading', position: 10),
        _book('c1', position: 100),
        _book('c2', position: 100),
        _book('u1'),
        _book('u2'),
      ],
      readAt: <String, int>{'marked': 9, 'atEnd': 8, 'reading': 1, 'c2': 7},
      completed: <String>{'marked', 'c1'},
      collections: <int, String>{7: 'A', 8: 'B'},
      membership: <String, (int, int)>{
        'c1': (7, 0),
        'c2': (7, 1),
        'u1': (8, 0),
        'u2': (8, 1),
      },
    );
    expect(_keys(s.select()), <String>['reading']);
  });

  test('候选按时刻倒序，并列保留输入顺序；孤儿合集引用按散书', () {
    final _Shelf s = _Shelf(
      books: <MediaItem>[
        _book('old', position: 1),
        _book('tieA', position: 1),
        _book('tieB', position: 1),
        _book('orphan', position: 1),
        _book('s1', position: 3),
      ],
      readAt: <String, int>{
        'old': 1,
        'tieA': 5,
        'tieB': 5,
        'orphan': 9,
        's1': 7,
      },
      membership: <String, (int, int)>{'s1': (7, 0), 'orphan': (99, 0)},
    );
    final List<BookContinueCandidate<MediaItem>> cs = s.select();
    expect(_keys(cs), <String>['orphan', 's1', 'tieA', 'tieB', 'old']);
    expect(cs.first.isSeries, isFalse);
    expect(cs[1].collectionId, 7);
    expect(cs[1].memberOrdinal, isNull, reason: '单卷合集不标卷号');
  });

  test('合集组内按 sortIndex 排，与输入顺序无关', () {
    final _Shelf s = _Shelf(
      books: <MediaItem>[
        _book('b', position: 100),
        _book('c'),
        _book('a', position: 100),
      ],
      readAt: <String, int>{'a': 1, 'b': 2},
      membership: <String, (int, int)>{'a': (7, 0), 'b': (7, 1), 'c': (7, 2)},
    );
    expect(_keys(s.select()), <String>['c']);
    expect(s.select().single.memberOrdinal, 3);
  });

  test('旧合集挂在 epub|<bookKey> 上：bookKey 换算成 uid 后查不中就退到旧键', () {
    final MediaItem item = _book('key1');
    final Map<String, int> primary = <String, int>{'epub|key1': 7};
    expect(
      bookCollectionEntryKey(
        item,
        epubUidByKey: <String, String>{'key1': 'uid1'},
        primaryCollectionIdByEntry: primary,
      ),
      'epub|key1',
    );
    expect(
      bookCollectionEntryKey(
        item,
        epubUidByKey: <String, String>{'key1': 'uid1'},
        primaryCollectionIdByEntry: <String, int>{'epub|uid1': 7},
      ),
      'epub|uid1',
    );
  });

  test('书 / 漫画分架：各自只在自己的书里选（与库页同一分架谓词）', () {
    final List<MediaItem> all = <MediaItem>[
      _book('novel', position: 10),
      _book('comic', position: 10, manga: true),
    ];
    final _Shelf s = _Shelf(
      books: all,
      readAt: <String, int>{'novel': 1, 'comic': 2},
    );
    final List<MediaItem> books = filterShelfEntriesByMangaSplit(
      all,
      mangaOnly: false,
    );
    final List<MediaItem> manga = filterShelfEntriesByMangaSplit(
      all,
      mangaOnly: true,
    );
    expect(_keys(s.select(from: books)), <String>['novel']);
    expect(_key(s.peek(from: books).resume!.item), 'novel');
    expect(_keys(s.select(from: manga)), <String>['comic']);
    expect(_key(s.peek(from: manga).resume!.item), 'comic');
  });

  test('速览「最近」= 其余候选，再接未被覆盖的最近读过条目，最多 4 项', () {
    final _Shelf s = _Shelf(
      books: <MediaItem>[
        _book('r1', position: 1),
        _book('r2', position: 1),
        _book('done', position: 100),
        _book('s1', position: 100),
        _book('s2'),
        _book('r3', position: 1),
        _book('r4', position: 1),
      ],
      readAt: <String, int>{
        'r1': 90,
        'r2': 80,
        'done': 85,
        's1': 70,
        'r3': 20,
        'r4': 10,
      },
      membership: <String, (int, int)>{'s1': (7, 0), 's2': (7, 1)},
    );
    final ({
      BookContinueCandidate<MediaItem>? resume,
      List<BookNavPeekItem<MediaItem>> recent,
    })
    plan = s.peek();
    expect(_key(plan.resume!.item), 'r1');
    expect(
      <String>[
        for (final BookNavPeekItem<MediaItem> e in plan.recent)
          _key(e.candidate?.item ?? e.read!.item),
      ],
      <String>['r2', 's2', 'r3', 'r4'],
    );
    // 候选不够 4 项时才轮到读完的书。
    final ({
      BookContinueCandidate<MediaItem>? resume,
      List<BookNavPeekItem<MediaItem>> recent,
    })
    small = _Shelf(
      books: <MediaItem>[
        _book('r1', position: 1),
        _book('done', position: 100),
      ],
      readAt: <String, int>{'r1': 90, 'done': 85},
    ).peek();
    expect(_key(small.recent.single.read!.item), 'done');
  });
}
