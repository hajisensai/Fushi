import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:test/test.dart';

/// 空操作写不发表变更通知（互联 client「一直在同步」）。
///
/// drift 的 insert（含 INSERT OR IGNORE 无操作、`DO UPDATE … WHERE` 不命中）与
/// `customUpdate(updates: …)` 一律发变更通知，UPDATE 同值也算命中行。合集观察者
/// （`installCollectionsSyncWatcher`）监听 book_tags / media_nsfw_flags /
/// media_collections / media_collection_items 等表，每收到一次就排一轮合集同步；
/// 这些被扫描、刮削、同步下载反复调的入口在「已是目标态」时必须纯读。
void main() {
  late FushiDatabase db;
  late List<Set<TableUpdate>> events;
  late StreamSubscription<Set<TableUpdate>> sub;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    events = <Set<TableUpdate>>[];
    sub = db
        .tableUpdates(
          TableUpdateQuery.onAllTables(
            <ResultSetImplementation<dynamic, dynamic>>[
              db.bookTags,
              db.tagAssignments,
              db.mediaNsfwFlags,
              db.mediaCollections,
              db.mediaCollectionItems,
              db.collectionMemberTombstones,
            ],
          ),
        )
        .listen(events.add);
  });

  tearDown(() async {
    await sub.cancel();
    await db.close();
  });

  /// 跑 [op] 并返回它引发的表变更事件数（通知异步投递，先排空事件队列）。
  Future<int> updatesDuring(Future<void> Function() op) async {
    await pumpEventQueue();
    events.clear();
    await op();
    await pumpEventQueue();
    return events.length;
  }

  group('getOrCreateTagByName', () {
    test('已存在同名标签时纯读：不发通知、返回同一 id', () async {
      late int first;
      expect(
        await updatesDuring(() async {
          first = await db.getOrCreateTagByName('MV');
        }),
        greaterThan(0),
      );
      late int second;
      expect(
        await updatesDuring(() async {
          second = await db.getOrCreateTagByName('MV');
        }),
        0,
      );
      expect(second, first);
      expect(await db.getAllTags(), hasLength(1));
    });
  });

  group('markMediaNsfwIfUndecided', () {
    test('已标过时纯读：不发通知、时钟不变', () async {
      expect(
        await updatesDuring(
          () => db.markMediaNsfwIfUndecided(
            TagHostKind.musicAlbum,
            'album-1',
            at: 100,
          ),
        ),
        greaterThan(0),
      );
      expect(
        await updatesDuring(
          () => db.markMediaNsfwIfUndecided(
            TagHostKind.musicAlbum,
            'album-1',
            at: 200,
          ),
        ),
        0,
      );
      final MediaNsfwClock clock = await db.mediaNsfwClock(
        TagHostKind.musicAlbum,
        'album-1',
      );
      expect(clock.nsfwAt, 100);
      expect(clock.clearedAt, isNull);
    });

    test('用户取消过时纯读：不发通知、保持取消', () async {
      await db.setMediaNsfw(TagHostKind.musicAlbum, 'album-2', false, at: 50);
      expect(
        await updatesDuring(
          () => db.markMediaNsfwIfUndecided(
            TagHostKind.musicAlbum,
            'album-2',
            at: 300,
          ),
        ),
        0,
      );
      expect(await db.isMediaNsfw(TagHostKind.musicAlbum, 'album-2'), isFalse);
    });
  });

  group('addToCollection', () {
    test('已是成员时（自动路径）不发通知、成员行不变', () async {
      final int id = await db.createMediaCollection(
        'S',
        collectionType: 'playlist',
      );
      await db.addToCollection(id, MediaKind.video, 'v1', userIntent: false);
      await db.addToCollection(id, MediaKind.video, 'v2', userIntent: false);
      final List<MediaCollectionItemRow> before = await db.getCollectionItems(
        id,
      );
      expect(
        await updatesDuring(
          () =>
              db.addToCollection(id, MediaKind.video, 'v1', userIntent: false),
        ),
        0,
      );
      final List<MediaCollectionItemRow> after = await db.getCollectionItems(
        id,
      );
      expect(
        after.map((MediaCollectionItemRow r) => (r.entryKey, r.sortIndex)),
        before.map((MediaCollectionItemRow r) => (r.entryKey, r.sortIndex)),
      );
    });

    test('用户合集上重复加已有成员（userIntent）不发通知', () async {
      final int id = await db.createMediaCollection('U');
      await db.addToCollection(id, MediaKind.video, 'v1');
      expect(
        await updatesDuring(
          () => db.addToCollection(id, MediaKind.video, 'v1'),
        ),
        0,
      );
    });

    test('规则合集被用户加成员仍转成 user、并发通知', () async {
      final int id = await db.createMediaCollection(
        'R',
        collectionType: 'playlist',
        origin: CollectionOrigin.rule,
      );
      await db.addToCollection(id, MediaKind.video, 'v1', userIntent: false);
      expect(
        await updatesDuring(
          () => db.addToCollection(id, MediaKind.video, 'v1'),
        ),
        greaterThan(0),
      );
      expect(
        (await db.getMediaCollectionById(id))!.origin,
        CollectionOrigin.user.dbValue,
      );
    });

    test('新成员照常插入并发通知', () async {
      final int id = await db.createMediaCollection('N');
      expect(
        await updatesDuring(
          () =>
              db.addToCollection(id, MediaKind.video, 'v9', userIntent: false),
        ),
        greaterThan(0),
      );
      expect(await db.getCollectionItems(id), hasLength(1));
    });
  });

  group('reorderCollectionItemsAutomatically', () {
    test('顺序已一致时不发通知；真改序时照常落库', () async {
      final int id = await db.createMediaCollection(
        'O',
        collectionType: 'playlist',
      );
      for (final String k in <String>['a', 'b', 'c']) {
        await db.addToCollection(id, MediaKind.video, k, userIntent: false);
      }
      final List<CollectionMemberKey> abc = <CollectionMemberKey>[
        for (final String k in <String>['a', 'b', 'c'])
          (mediaType: MediaKind.video.dbValue, entryKey: k),
      ];
      await db.reorderCollectionItemsAutomatically(id, abc);
      expect(
        await updatesDuring(
          () => db.reorderCollectionItemsAutomatically(id, abc),
        ),
        0,
      );
      final List<CollectionMemberKey> cba = abc.reversed.toList();
      expect(
        await updatesDuring(
          () => db.reorderCollectionItemsAutomatically(id, cba),
        ),
        greaterThan(0),
      );
      expect(
        (await db.getCollectionItems(id))
            .map((MediaCollectionItemRow r) => (r.entryKey, r.sortIndex))
            .toList(),
        <(String, int)>[('c', 0), ('b', 1), ('a', 2)],
      );
    });
  });
}
