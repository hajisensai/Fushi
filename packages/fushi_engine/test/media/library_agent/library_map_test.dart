// AI 管库 v3 §3.2 `library.map`（docs/specs/2026-11-22-ai-library-agent-design.md）：
// 真 schema 的内存库上验 summary / 域视图 / links 三种视图、分页、标题过滤、墓碑连接
// 不出现、上锁的作品（自身上锁 / 在上锁合集里）不交给模型。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/library_agent/library_map.dart';
import 'package:test/test.dart';

void main() {
  late FushiDatabase db;
  final Map<String, String> uids = <String, String>{};

  Future<void> book(String key, String title, {bool manga = false}) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: key,
        title: title,
        author: const Value<String?>('作者'),
        epubPath: '/secret/path/$key.epub',
        extractDir: '/x/$key',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1,
        format: Value<String>(manga ? 'manga' : 'epub'),
      ),
    );
    uids[key] = (await db.getEpubBook(key))!.uid;
  }

  Future<void> collection(
    int id,
    String name, {
    String origin = 'user',
    String type = 'playlist',
    String? folder,
  }) => db.customStatement(
    'INSERT INTO media_collections '
    '(id, name, collection_type, created_at, origin, source_folder_path) '
    'VALUES (?, ?, ?, 1, ?, ?)',
    <Object?>[id, name, type, origin, folder],
  );

  Future<void> member(
    int collection,
    String mediaType,
    String key, {
    bool pinned = false,
  }) => db.customStatement(
    'INSERT INTO media_collection_items '
    '(collection_id, media_type, entry_key, pinned_by_user) VALUES (?, ?, ?, ?)',
    <Object?>[collection, mediaType, key, pinned ? 1 : 0],
  );

  Future<void> link(
    String from,
    String relation,
    String to, {
    String? confirmedBy,
    String source = 'manual',
    String? role,
    int? deletedAt,
  }) {
    final int fc = from.indexOf(':');
    final int tc = to.indexOf(':');
    return db.customStatement(
      'INSERT INTO media_links (from_kind, from_key, relation, to_kind, to_key, '
      'role, source, is_user_confirmed, confirmed_by, created_at, updated_at, '
      'deleted_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 1, ?)',
      <Object?>[
        from.substring(0, fc),
        from.substring(fc + 1),
        relation,
        to.substring(0, tc),
        to.substring(tc + 1),
        role,
        source,
        confirmedBy == 'user' ? 1 : 0,
        confirmedBy,
        deletedAt,
      ],
    );
  }

  String epub(String key) => 'epub:${uids[key]}';

  Map<String, Object?> rowOf(Map<String, Object?> table, int i) {
    final List<Object?> columns = table['columns']! as List<Object?>;
    final List<Object?> row = (table['rows']! as List<Object?>)[i]! as List;
    return <String, Object?>{
      for (int c = 0; c < columns.length; c++) columns[c]! as String: row[c],
    };
  }

  List<Object?> column(Map<String, Object?> table, String name) {
    final int c = (table['columns']! as List<Object?>).indexOf(name);
    return <Object?>[
      for (final Object? row in table['rows']! as List<Object?>)
        (row! as List<Object?>)[c],
    ];
  }

  Future<Map<String, Object?>> map(Map<String, Object?> args) =>
      loadLibraryMap(db, LibraryMapQuery.fromJson(args));

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    uids.clear();
    await book('b1', '鬼滅の刃 1');
    await book('b2', '鬼滅の刃 2');
    await book('b3', '呪術廻戦');
    await book('b4', 'Loose Book');
    await book('b5', 'Folder Book');
    await book('b6', 'Secret Book'); // 自身上锁
    await book('b7', 'Hidden Member'); // 在上锁合集里
    await book('m1', 'One Piece', manga: true);
    for (final String v in <String>['v1', 'v2']) {
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: v,
          title: 'Episode $v',
          videoPath: 'D:/Anime/Kimetsu S1/$v.mkv',
        ),
      );
    }

    await collection(1, 'Kimetsu', origin: 'ai');
    await member(1, 'epub', uids['b1']!);
    await member(1, 'epub', uids['b2']!, pinned: true);
    await collection(2, 'Jujutsu', type: 'collection');
    await member(2, 'epub', uids['b3']!);
    await collection(3, 'Folder', origin: 'folder', folder: '/secret/folder');
    await member(3, 'epub', uids['b5']!);
    await collection(4, 'Kimetsu Anime');
    await member(4, 'video', 'v1');
    await member(4, 'video', 'v2');
    await collection(5, 'Hidden');
    await member(5, 'epub', uids['b7']!);

    await db.setMediaLocked(TagHostKind.epub, 'b6', true);
    await db.setMediaLocked(TagHostKind.collection, '5', true);

    await link(
      'book:b1',
      'adaptation',
      'video_collection:4',
      confirmedBy: 'user',
    );
    await link('book:b1', 'sequel', 'book:b2', confirmedBy: 'ai', source: 'ai');
    await link('book:b3', 'adaptation', 'book:b4', source: 'mal');
    await link(
      'video_collection:4',
      'theme_song',
      'music_track:t1',
      confirmedBy: 'user',
      role: 'op',
    );
    await link(
      'book:b4',
      'adaptation',
      'video_episode:v9',
      confirmedBy: 'user',
      deletedAt: 5,
    );
    await link('book:b6', 'adaptation', 'book:b3', confirmedBy: 'user');
  });

  tearDown(() => db.close());

  test('summary：各域计数、合集按来源、关系按状态（墓碑 / 上锁不计）、作品数', () async {
    final Map<String, Object?> s = await map(<String, Object?>{});
    expect(s['view'], 'summary');
    final Map<String, Object?> domains = s['domains']! as Map<String, Object?>;
    expect(domains['books'], <String, Object?>{
      'items': 5,
      'loose': 1,
      'collections': 3,
      'collectionsByOrigin': <String, int>{
        'ai': 1,
        'rule': 0,
        'folder': 1,
        'user': 1,
      },
    });
    expect((domains['manga']! as Map<String, Object?>)['items'], 1);
    expect((domains['manga']! as Map<String, Object?>)['loose'], 1);
    expect((domains['video']! as Map<String, Object?>)['items'], 2);
    expect((domains['video']! as Map<String, Object?>)['loose'], 0);
    expect((domains['games']! as Map<String, Object?>)['items'], 0);
    expect(s['links'], <String, Object?>{
      'total': 4,
      'user': 2,
      'ai': 1,
      'suggested': 1,
    });
    expect(s['works'], 1);
  });

  test('books 视图：合集列（来源 / 钉住 / 目录）、条目列（端点引用），不含路径与上锁', () async {
    final Map<String, Object?> r = await map(<String, Object?>{
      'view': 'books',
    });
    expect(r['total'], 8);
    expect(r['nextOffset'], isNull);
    final Map<String, Object?> cols = r['collections']! as Map<String, Object?>;
    expect(column(cols, 'ref'), <String>['C1', 'C2', 'C3']);
    expect(rowOf(cols, 0), <String, Object?>{
      'ref': 'C1',
      'name': 'Kimetsu',
      'type': 'playlist',
      'origin': 'ai',
      'memberCount': 2,
      'members': (<String>[epub('b1'), epub('b2')]..sort()),
      'pinned': <String>[epub('b2')],
      'isFolder': false,
      'endpoint': null,
    });
    expect(rowOf(cols, 2)['origin'], 'folder');
    expect(rowOf(cols, 2)['isFolder'], isTrue);

    final Map<String, Object?> items = r['items']! as Map<String, Object?>;
    // 按所在合集聚拢，散条目排最后；目录合集成员也在。
    expect(column(items, 'ref'), <String>[
      epub('b1'),
      epub('b2'),
      epub('b3'),
      epub('b5'),
      epub('b4'),
    ]);
    expect(rowOf(items, 0), <String, Object?>{
      'ref': epub('b1'),
      'title': '鬼滅の刃 1',
      'creator': '作者',
      'year': null,
      'folder': null,
      'collections': <String>['C1'],
      'endpoint': 'book:b1',
    });
    expect(rowOf(items, 4)['collections'], isEmpty);
    final String dump = r.toString();
    expect(dump, isNot(contains('/secret')));
    expect(dump, isNot(contains('Secret Book')));
    expect(dump, isNot(contains('Hidden')));
  });

  test('video 视图：文件夹只给末级名，合集带视频合集端点', () async {
    final Map<String, Object?> r = await map(<String, Object?>{
      'view': 'video',
    });
    final Map<String, Object?> cols = r['collections']! as Map<String, Object?>;
    expect(rowOf(cols, 0)['ref'], 'C4');
    expect(rowOf(cols, 0)['endpoint'], 'video_collection:4');
    expect(rowOf(cols, 0)['members'], <String>['video:v1', 'video:v2']);
    final Map<String, Object?> items = r['items']! as Map<String, Object?>;
    expect(rowOf(items, 0)['ref'], 'video:v1');
    expect(rowOf(items, 0)['folder'], 'Kimetsu S1');
    expect(rowOf(items, 0)['endpoint'], 'video_episode:v1');
    expect(r.toString(), isNot(contains('D:/Anime')));
  });

  test('分页：合集行在前、条目行在后，total / nextOffset', () async {
    final Map<String, Object?> p1 = await map(<String, Object?>{
      'view': 'books',
      'limit': 2,
    });
    expect(p1['total'], 8);
    expect(p1['nextOffset'], 2);
    expect(column(p1['collections']! as Map<String, Object?>, 'ref'), <String>[
      'C1',
      'C2',
    ]);
    expect((p1['items']! as Map<String, Object?>)['rows'], isEmpty);

    final Map<String, Object?> p2 = await map(<String, Object?>{
      'view': 'books',
      'offset': 2,
      'limit': 2,
    });
    expect(p2['nextOffset'], 4);
    expect(column(p2['collections']! as Map<String, Object?>, 'ref'), <String>[
      'C3',
    ]);
    expect(column(p2['items']! as Map<String, Object?>, 'ref'), <String>[
      epub('b1'),
    ]);

    final Map<String, Object?> last = await map(<String, Object?>{
      'view': 'books',
      'offset': 6,
      'limit': 5,
    });
    expect(last['nextOffset'], isNull);
    expect(column(last['items']! as Map<String, Object?>, 'ref'), <String>[
      epub('b5'),
      epub('b4'),
    ]);
  });

  test('q 过滤：折叠标题匹配条目；命中合集带出全部成员', () async {
    final Map<String, Object?> byItem = await map(<String, Object?>{
      'view': 'books',
      'q': '鬼滅',
    });
    expect(
      column(byItem['collections']! as Map<String, Object?>, 'ref'),
      <String>['C1'],
    );
    expect(column(byItem['items']! as Map<String, Object?>, 'ref'), <String>[
      epub('b1'),
      epub('b2'),
    ]);

    // 全角 / 大写折叠后命中合集名，带出成员（成员标题本身不含 jujutsu）。
    final Map<String, Object?> byCollection = await map(<String, Object?>{
      'view': 'books',
      'q': 'ＪＵＪＵＴＳＵ',
    });
    expect(
      column(byCollection['collections']! as Map<String, Object?>, 'ref'),
      <String>['C2'],
    );
    expect(
      column(byCollection['items']! as Map<String, Object?>, 'ref'),
      <String>[epub('b3')],
    );
  });

  test('links 视图：作品 + 边（含卫星）+ 标题；墓碑与上锁端点的连接不出现', () async {
    final Map<String, Object?> r = await map(<String, Object?>{
      'view': 'links',
    });
    expect(r['total'], 2);
    expect(r['nextOffset'], isNull);
    final Map<String, Object?> works = r['works']! as Map<String, Object?>;
    expect(rowOf(works, 0), <String, Object?>{
      'work': 1,
      'name': 'Kimetsu Anime',
      'isWork': true,
      'members': <String>['book:b1', 'book:b2', 'video_collection:4'],
    });
    expect(rowOf(works, 1)['isWork'], isFalse);
    expect(rowOf(works, 1)['members'], <String>['book:b3', 'book:b4']);

    final Map<String, Object?> edges = r['edges']! as Map<String, Object?>;
    final List<String> flat = <String>[
      for (final Object? row in edges['rows']! as List<Object?>)
        (row! as List<Object?>).take(4).join(' '),
    ];
    expect(flat, <String>[
      'book:b1 video_collection:4 adaptation user',
      'book:b1 book:b2 sequel ai',
      'video_collection:4 music_track:t1 theme_song user',
      'book:b3 book:b4 adaptation suggested',
    ]);
    expect(rowOf(edges, 2)['role'], 'op');
    expect(rowOf(edges, 1)['source'], 'ai');
    final Map<String, Object?> titles = r['titles']! as Map<String, Object?>;
    expect(titles['book:b1'], '鬼滅の刃 1');
    expect(titles['video_collection:4'], 'Kimetsu Anime');
    final String dump = r.toString();
    expect(dump, isNot(contains('v9')));
    expect(dump, isNot(contains('b6')));
  });

  test('links 视图：分页按作品、q 按端点标题过滤（编号不变）', () async {
    final Map<String, Object?> p = await map(<String, Object?>{
      'view': 'links',
      'limit': 1,
    });
    expect(p['nextOffset'], 1);
    expect(
      ((p['edges']! as Map<String, Object?>)['rows']! as List),
      hasLength(3),
    );
    final Map<String, Object?> f = await map(<String, Object?>{
      'view': 'links',
      'q': 'loose book',
    });
    expect(f['total'], 1);
    expect(rowOf(f['works']! as Map<String, Object?>, 0)['work'], 2);
  });

  test('fromJson 校验', () {
    expect(
      () => LibraryMapQuery.fromJson(<String, Object?>{'view': 'nope'}),
      throwsFormatException,
    );
    expect(
      () => LibraryMapQuery.fromJson(<String, Object?>{'offset': -1}),
      throwsFormatException,
    );
    final LibraryMapQuery q = LibraryMapQuery.fromJson(<String, Object?>{
      'view': 'links',
      'q': '  ',
      'limit': 99999,
    });
    expect(q.view, LibraryMapView.links);
    expect(q.q, isNull);
    expect(q.limit, LibraryMapQuery.maxLimit);
    expect(LibraryMapQuery.fromJson(<String, Object?>{}).limit, 400);
  });
}
