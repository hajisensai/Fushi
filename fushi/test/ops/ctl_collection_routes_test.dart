import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';

import 'package:fushi/src/media/collections/collection_one_key_sort.dart'
    show collectionDetailSortPrefKey, kCollectionDetailManualSortValue;
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/ops/ctl_collection_routes.dart';
import 'package:fushi/src/ops/ctl_library_manage_routes.dart'
    show kLibraryCtlManageRoot;
import 'package:fushi/src/ops/ctl_library_shelf.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_routes.dart';

class _NoAi implements AiSettingsSource {
  @override
  AiFeatureAssignments get aiFeatureAssignments => const AiFeatureAssignments();

  @override
  List<AiProviderConfig> get aiProviders => const <AiProviderConfig>[];

  @override
  List<WebKnowledgeSite> get aiWebKnowledgeSites => const <WebKnowledgeSite>[];
}

class _UnusedRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('构造路由表时不应访问 ref');
}

MediaCollectionItemRow _row(String mediaType, String entryKey) =>
    MediaCollectionItemRow(
      collectionId: 1,
      mediaType: mediaType,
      entryKey: entryKey,
      sortIndex: 0,
    );

Matcher _status(int status) => throwsA(
  isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', status),
);

void main() {
  late FushiDatabase db;
  late LibraryCtlShelf shelf;
  late List<CtlRoute> routes;
  late int collectionId;
  bool readonly = false;

  Future<void> addVideo(String uid, String file) => db.upsertVideoBook(
    VideoBooksCompanion(
      bookUid: Value<String>(uid),
      title: Value<String>(file),
      videoPath: Value<String>('/a/$file'),
    ),
  );

  setUp(() async {
    readonly = false;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    shelf = LibraryCtlShelf(db: db, galgameRepo: GalgameRepository(db));
    routes = buildCollectionCtlRoutesFor(
      database: () => db,
      shelf: () => shelf,
      aiSettings: _NoAi.new,
      isReadonly: () => readonly,
    );
    collectionId = await db.createMediaCollection(
      'Show',
      collectionType: 'playlist',
    );
    for (final (String uid, String file) in <(String, String)>[
      ('v2', 'Show - 02.mkv'),
      ('vsp', 'Show - SP.mkv'),
      ('v1', 'Show - 01.mkv'),
    ]) {
      await addVideo(uid, file);
      await db.addToCollection(collectionId, MediaKind.video, uid);
    }
  });

  tearDown(() => db.close());

  Future<Object?> call(
    String method,
    String path, {
    Map<String, Object?> body = const <String, Object?>{},
  }) {
    for (final CtlRoute route in routes) {
      if (route.method != method) continue;
      final Map<String, String>? params = route.match(path);
      if (params == null) continue;
      return route.handler(
        CtlCall(method: method, path: path, params: params, body: body),
      );
    }
    throw StateError('没有路由 $method $path');
  }

  Future<List<String>> order() async => <String>[
    for (final MediaCollectionItemRow r in await db.getCollectionItems(
      collectionId,
    ))
      r.entryKey,
  ];

  group('注册：与书架管理同一套合集路由，不另立根', () {
    test('定序路由在 library/collections 下，method + path 不重复', () {
      expect(kCollectionCtlRoot, '$kLibraryCtlManageRoot/collections');
      final Set<String> seen = <String>{};
      for (final CtlRoute route in routes) {
        expect(route.pattern, startsWith(kCollectionCtlRoot));
        expect(seen.add('${route.method} ${route.pattern}'), isTrue);
      }
      expect(seen, <String>{
        'PUT $kCollectionCtlRoot/:id/order',
        'POST $kCollectionCtlRoot/:id/sort',
      });
    });

    test('总路由表：合集列表只有一条、定序各一条，没有旧的 /api/admin/collections', () {
      final List<CtlRoute> all = buildOpRoutes(
        OpContext(ref: _UnusedRef(), focusMainWindow: () async {}),
      );
      final List<String> keys = <String>[
        for (final CtlRoute r in all) '${r.method} ${r.pattern}',
      ];
      expect(keys.toSet(), hasLength(keys.length), reason: '路由重复注册');
      for (final String expected in <String>[
        'GET $kCollectionCtlRoot',
        'GET $kCollectionCtlRoot/:id',
        'PUT $kCollectionCtlRoot/:id/order',
        'POST $kCollectionCtlRoot/:id/sort',
      ]) {
        expect(keys.where((String k) => k == expected), hasLength(1));
      }
      expect(
        all.where(
          (CtlRoute r) => r.pattern.startsWith('/api/admin/collections'),
        ),
        isEmpty,
      );
    });
  });

  test('order：条目键 + 本合集唯一的裸 id（子集合法）、bump orderUpdatedAt、切 manual', () async {
    final Map<String, Object?> detail =
        await call(
              'PUT',
              '$kCollectionCtlRoot/$collectionId/order',
              body: <String, Object?>{
                'keys': <String>['video:v1', 'v2'],
              },
            )
            as Map<String, Object?>;
    expect(await order(), <String>['v1', 'vsp', 'v2']);
    // 回的是与 `collection get` 同形的详情。
    expect(
      (detail['items']! as List<Object?>).map(
        (Object? r) => (r! as Map<String, Object?>)['key'],
      ),
      <String>['video:v1', 'video:vsp', 'video:v2'],
    );
    expect(detail['manualOrder'], isTrue);
    expect(
      (await db.getMediaCollectionById(collectionId))!.orderUpdatedAt,
      greaterThan(0),
    );
    expect(
      await db.getPref(collectionDetailSortPrefKey(collectionId)),
      kCollectionDetailManualSortValue,
    );
  });

  test('sort --by title：dry-run 不落盘，正式落盘；order 用条目键', () async {
    final Map<String, Object?> dry =
        await call(
              'POST',
              '$kCollectionCtlRoot/$collectionId/sort',
              body: <String, Object?>{'by': 'title', 'dryRun': true},
            )
            as Map<String, Object?>;
    expect(dry['persisted'], isFalse);
    expect(dry['changed'], isTrue);
    expect(
      (dry['order']! as List<Object?>).map(
        (Object? r) => (r! as Map<String, Object?>)['key'],
      ),
      <String>['video:v1', 'video:v2', 'video:vsp'],
    );
    expect(await order(), <String>['v2', 'vsp', 'v1']);
    await call(
      'POST',
      '$kCollectionCtlRoot/$collectionId/sort',
      body: <String, Object?>{'by': 'title'},
    );
    expect(await order(), <String>['v1', 'v2', 'vsp']);
  });

  test('sort --by ai 没指派提供商 → 422，顺序不动', () async {
    await expectLater(
      call(
        'POST',
        '$kCollectionCtlRoot/$collectionId/sort',
        body: <String, Object?>{'by': 'ai'},
      ),
      _status(422),
    );
    expect(await order(), <String>['v2', 'vsp', 'v1']);
  });

  test('迁移只读：order / 落盘 sort 被拒，dry-run 放行', () async {
    readonly = true;
    await expectLater(
      call(
        'PUT',
        '$kCollectionCtlRoot/$collectionId/order',
        body: <String, Object?>{
          'keys': <String>['video:v1'],
        },
      ),
      _status(422),
    );
    await expectLater(
      call(
        'POST',
        '$kCollectionCtlRoot/$collectionId/sort',
        body: <String, Object?>{'by': 'title'},
      ),
      _status(422),
    );
    final Map<String, Object?> dry =
        await call(
              'POST',
              '$kCollectionCtlRoot/$collectionId/sort',
              body: <String, Object?>{'by': 'title', 'dryRun': true},
            )
            as Map<String, Object?>;
    expect(dry['persisted'], isFalse);
    expect(await order(), <String>['v2', 'vsp', 'v1']);
  });

  test('不存在的合集 404，坏 id / 坏 by 400', () async {
    await expectLater(
      call(
        'POST',
        '$kCollectionCtlRoot/999/sort',
        body: <String, Object?>{'by': 'title'},
      ),
      _status(404),
    );
    await expectLater(
      call(
        'POST',
        '$kCollectionCtlRoot/abc/sort',
        body: <String, Object?>{'by': 'title'},
      ),
      _status(400),
    );
    await expectLater(
      call(
        'POST',
        '$kCollectionCtlRoot/$collectionId/sort',
        body: <String, Object?>{'by': 'rating'},
      ),
      _status(400),
    );
  });

  group('resolveCollectionCtlKeys', () {
    final List<({MediaCollectionItemRow row, String key})> rows =
        <({MediaCollectionItemRow row, String key})>[
          (row: _row('video', 'a'), key: 'video:a'),
          (row: _row('srt', 'x'), key: 'srt:x'),
          // epub 成员行存 uid，条目键是 book:<bookKey>（collection get 的形状）。
          (row: _row('epub', 'uid-x'), key: 'book:x'),
        ];

    test('认条目键与本合集唯一的裸 id', () {
      expect(
        resolveCollectionCtlKeys(rows, <String>['srt:x', 'book:x', 'a']),
        <CollectionMemberKey>[
          (mediaType: 'srt', entryKey: 'x'),
          (mediaType: 'epub', entryKey: 'uid-x'),
          (mediaType: 'video', entryKey: 'a'),
        ],
      );
    });

    test('认不出 / 有歧义 / 重复给出一律 400，不静默丢', () {
      for (final List<String> bad in <List<String>>[
        <String>['nope'],
        <String>['x'],
        <String>['a', 'video:a'],
      ]) {
        expect(
          () => resolveCollectionCtlKeys(rows, bad),
          throwsA(isA<CtlFailure>()),
          reason: '$bad',
        );
      }
    });
  });

  group('成员数口径 = 库页可见成员（BUG-3361）', () {
    Future<String> addBook(String bookKey) async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: bookKey,
          title: bookKey,
          epubPath: '/x/$bookKey.epub',
          extractDir: '/x/$bookKey',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: 1000,
        ),
      );
      return (await db.resolveEpubBookUid(bookKey))!;
    }

    test('删掉的视频、伴生 EPUB、孤儿游戏 / 有声书行不计入 members，get 标出不可见', () async {
      // 视频合集：3 个本机视频 + 1 条已删除视频留下的孤儿行。
      await db.addToCollection(collectionId, MediaKind.video, 'gone');

      // 书合集：独立 EPUB（可见）+ 有声书（可见）+ 该有声书的伴生 EPUB（书架只画
      // 有声书卡，不可见）+ 孤儿有声书 / 游戏行。
      final int books = await db.createMediaCollection('Books');
      final String plainUid = await addBook('plain');
      final String pairedUid = await addBook('paired');
      await SrtBookRepository(db).save(
        SrtBook()
          ..uid = 'srtbook_1'
          ..title = 'paired'
          ..srtPath = '/x/paired.srt'
          ..importedAt = 1
          ..bookKey = 'paired',
      );
      await db.addToCollection(books, MediaKind.epub, plainUid);
      await db.addToCollection(books, MediaKind.epub, pairedUid);
      await db.addToCollection(books, MediaKind.srt, 'srtbook_1');
      await db.addToCollection(books, MediaKind.srt, 'srtbook_gone');
      await db.addToCollection(books, MediaKind.game, 'no-such-game');

      final Map<int, Object?> members = <int, Object?>{
        for (final Map<String, Object?> c in await shelf.listCollections())
          c['id']! as int: c['members'],
      };
      expect(members[collectionId], 3);
      expect(members[books], 2);

      final Map<String, Object?> detail = await shelf.collectionDetail(books);
      expect(detail['members'], 2);
      final List<Object?> items = detail['items']! as List<Object?>;
      expect(items, hasLength(5), reason: '不可见的行仍列出，便于 remove / order 点名');
      expect(
        <Object?, Object?>{
          for (final Map<String, Object?> r
              in items.cast<Map<String, Object?>>())
            r['entryKey']: r['visible'],
        },
        <Object?, Object?>{
          plainUid: true,
          pairedUid: false,
          'srtbook_1': true,
          'srtbook_gone': false,
          'no-such-game': false,
        },
      );
    });
  });
}
