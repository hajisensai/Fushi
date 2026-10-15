import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';

import 'package:fushi/src/media/collections/collection_one_key_sort.dart'
    show collectionDetailSortPrefKey, kCollectionDetailManualSortValue;
import 'package:fushi/src/platform/desktop/ctl/ctl_collection_routes.dart';

class _NoAi implements AiSettingsSource {
  @override
  AiFeatureAssignments get aiFeatureAssignments => const AiFeatureAssignments();

  @override
  List<AiProviderConfig> get aiProviders => const <AiProviderConfig>[];

  @override
  List<WebKnowledgeSite> get aiWebKnowledgeSites => const <WebKnowledgeSite>[];
}

MediaCollectionItemRow _row(String mediaType, String entryKey) =>
    MediaCollectionItemRow(
      collectionId: 1,
      mediaType: mediaType,
      entryKey: entryKey,
      sortIndex: 0,
    );

void main() {
  late FushiDatabase db;
  late List<CtlRoute> routes;
  late int collectionId;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    routes = buildCollectionCtlRoutesFor(
      database: () => db,
      aiSettings: _NoAi.new,
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
      await db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: Value<String>(uid),
          title: Value<String>(file),
          videoPath: Value<String>('/a/$file'),
        ),
      );
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

  test('路由都在 /api/admin/collections 下，method + path 不重复', () {
    final Set<String> seen = <String>{};
    for (final CtlRoute route in routes) {
      expect(route.pattern, startsWith(kCollectionCtlRoot));
      expect(seen.add('${route.method} ${route.pattern}'), isTrue);
    }
  });

  test('ls 列出合集与成员数；items 按 sortIndex 给出成员键与标题', () async {
    final Map<String, Object?> ls =
        await call('GET', kCollectionCtlRoot) as Map<String, Object?>;
    final List<Object?> collections = ls['collections']! as List<Object?>;
    expect(collections, hasLength(1));
    expect(collections.single, containsPair('members', 3));
    expect(collections.single, containsPair('manualOrder', false));

    final Map<String, Object?> items =
        await call('GET', '$kCollectionCtlRoot/$collectionId/items')
            as Map<String, Object?>;
    final List<Object?> rows = items['items']! as List<Object?>;
    expect(
      rows.map((Object? r) => (r! as Map<String, Object?>)['key']),
      <String>['video:v2', 'video:vsp', 'video:v1'],
    );
    expect(rows.first, containsPair('title', 'Show - 02.mkv'));
  });

  test('order：手动定序（子集合法）、bump orderUpdatedAt、切 manual', () async {
    await call(
      'PUT',
      '$kCollectionCtlRoot/$collectionId/order',
      body: <String, Object?>{
        'keys': <String>['video:v1', 'v2'],
      },
    );
    expect(await order(), <String>['v1', 'vsp', 'v2']);
    expect(
      (await db.getMediaCollectionById(collectionId))!.orderUpdatedAt,
      greaterThan(0),
    );
    expect(
      await db.getPref(collectionDetailSortPrefKey(collectionId)),
      kCollectionDetailManualSortValue,
    );
  });

  test('sort --by title：dry-run 不落盘，正式落盘', () async {
    final Map<String, Object?> dry =
        await call(
              'POST',
              '$kCollectionCtlRoot/$collectionId/sort',
              body: <String, Object?>{'by': 'title', 'dryRun': true},
            )
            as Map<String, Object?>;
    expect(dry['persisted'], isFalse);
    expect(dry['changed'], isTrue);
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
      throwsA(
        isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 422),
      ),
    );
    expect(await order(), <String>['v2', 'vsp', 'v1']);
  });

  test('不存在的合集 404，坏 id / 坏 by 400', () async {
    await expectLater(
      call('GET', '$kCollectionCtlRoot/999/items'),
      throwsA(
        isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 404),
      ),
    );
    await expectLater(
      call('GET', '$kCollectionCtlRoot/abc/items'),
      throwsA(
        isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 400),
      ),
    );
    await expectLater(
      call(
        'POST',
        '$kCollectionCtlRoot/$collectionId/sort',
        body: <String, Object?>{'by': 'rating'},
      ),
      throwsA(
        isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 400),
      ),
    );
  });

  group('resolveCollectionCtlKeys', () {
    final List<MediaCollectionItemRow> rows = <MediaCollectionItemRow>[
      _row('video', 'a'),
      _row('srt', 'x'),
      _row('epub', 'x'),
    ];

    test('认 type:key、type|key 与本合集唯一的裸 key', () {
      expect(
        resolveCollectionCtlKeys(rows, <String>['srt:x', 'epub|x', 'a']),
        <CollectionMemberKey>[
          (mediaType: 'srt', entryKey: 'x'),
          (mediaType: 'epub', entryKey: 'x'),
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
}
