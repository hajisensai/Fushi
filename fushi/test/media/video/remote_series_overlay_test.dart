// 媒体服务器剧名合集「懒收养」（BUG-5601）：叠加 vs 收养对拍、物化、负 id 护栏。
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:fushi/src/media/video/video_continue_watching.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/remote_series_overlay.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/remote_collection_adoption_service.dart';
import 'package:test/test.dart';

const String _type = 'playlist';

RemoteVideoInfo _ep(String id, String series, int slot) => RemoteVideoInfo(
  id: id,
  title: id,
  collection: RemoteCollectionMembership(
    collectionName: series,
    collectionType: _type,
    sortIndex: slot,
  ),
);

/// 用户库的几种形状：普通剧、删过的剧、移出过一集的剧、手排过且已有成员的真合集、
/// 别处已有主归属的集、电影（无归属）。
List<RemoteVideoInfo> _catalog() => <RemoteVideoInfo>[
  _ep('video/a1', 'Alpha', 0),
  _ep('video/a2', 'Alpha', 1),
  _ep('video/a3', 'Alpha', 2),
  _ep('video/d1', 'Deleted', 0),
  _ep('video/d2', 'Deleted', 1),
  _ep('video/r1', 'Removed', 0),
  _ep('video/r2', 'Removed', 1),
  _ep('video/r3', 'Removed', 2),
  _ep('video/m1', 'Manual', 0),
  _ep('video/m2', 'Manual', 1),
  _ep('video/m3', 'Manual', 2),
  _ep('video/u1', 'Unordered', 5),
  _ep('video/u2', 'Unordered', 6),
  _ep('video/o1', 'Other', 0),
  _ep('video/o2', 'Other', 1),
  const RemoteVideoInfo(id: 'video/movie', title: 'movie'),
];

/// 两个库上同样的前置状态。
Future<void> _seed(FushiDatabase db) async {
  // 先建一个无关合集占掉 id 1，后面的真合集 id 不与「从 1 起分配」的巧合对上。
  await db.createMediaCollection('Unrelated');
  final int manual = await db.createMediaCollection(
    'Manual',
    collectionType: _type,
  );
  await db.addToCollection(manual, MediaKind.video, 'video/m2');
  await db.addToCollection(manual, MediaKind.video, 'video/local-x');
  await db.setCollectionOrderUpdatedAt(manual, 5);
  await db.createMediaCollection('Unordered', collectionType: _type);
  final int shelf = await db.createMediaCollection('Shelf');
  await db.addToCollection(shelf, MediaKind.video, 'video/o1');
  await db.upsertCollectionMemberTombstone(
    collectionName: 'Deleted',
    collectionType: _type,
    mediaType: FushiDatabase.collectionTombstoneSentinel,
    entryKey: FushiDatabase.collectionTombstoneSentinel,
    deletedAt: 10,
  );
  await db.upsertCollectionMemberTombstone(
    collectionName: 'Removed',
    collectionType: _type,
    mediaType: MediaKind.video.dbValue,
    entryKey: 'video/r2',
    deletedAt: 10,
  );
}

/// 合集 id → 自然键（真行 + 虚拟行），对拍时不比较 id 本身。
Map<int, String> _keysOf(
  List<MediaCollectionRow> collections,
  Map<int, MediaCollectionRow> virtual,
) => <int, String>{
  for (final MediaCollectionRow c in collections)
    c.id: remoteSeriesNaturalKey(c.name, c.collectionType),
  for (final MediaCollectionRow c in virtual.values)
    c.id: remoteSeriesNaturalKey(c.name, c.collectionType),
};

void main() {
  setUp(() {
    debugVideoMembershipInline = true;
    VirtualCollectionRegistry.instance.debugReset();
  });
  tearDown(() {
    debugVideoMembershipInline = false;
    VirtualCollectionRegistry.instance.debugReset();
  });

  test('对拍：叠加出的折叠归属 / 组内序 = 收养落库后读出的（按自然键比较）', () async {
    final FushiDatabase adopted = FushiDatabase.forTesting(
      NativeDatabase.memory(),
    );
    final FushiDatabase lazy = FushiDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(adopted.close);
    addTearDown(lazy.close);
    await _seed(adopted);
    await _seed(lazy);
    final List<RemoteVideoInfo> catalog = _catalog();

    await RemoteCollectionAdoptionService(adopted).adoptVideos(catalog);
    final VideoLibraryMembership oldWay = await loadVideoLibraryMembership(
      adopted,
      books: const <VideoBookRow>[],
      series: RemoteSeriesColumns.empty,
    );
    final VideoLibraryMembership newWay = await loadVideoLibraryMembership(
      lazy,
      books: const <VideoBookRow>[],
      series: RemoteSeriesColumns.fromVideos(catalog),
    );

    final Map<int, String> oldKeys = _keysOf(
      await adopted.getAllMediaCollections(),
      oldWay.virtualCollections,
    );
    final Map<int, String> newKeys = _keysOf(
      await lazy.getAllMediaCollections(),
      newWay.virtualCollections,
    );
    Map<String, String> byName(Map<String, int> p, Map<int, String> k) =>
        <String, String>{
          for (final MapEntry<String, int> e in p.entries) e.key: k[e.value]!,
        };
    expect(
      byName(newWay.primary, newKeys),
      byName(oldWay.primary, oldKeys),
      reason: '同一份目录：叠加与收养给出同样的折叠归属',
    );
    expect(newWay.memberSortIndex, oldWay.memberSortIndex);
    // 前提核对：各条规则真的被这份数据踩到了。
    expect(newWay.primary.containsKey('video|video/d1'), isFalse);
    expect(newWay.primary.containsKey('video|video/r2'), isFalse);
    expect(newWay.primary['video|video/r1'], isNegative);
    expect(newWay.primary['video|video/m1'], isPositive);
    expect(newWay.memberSortIndex['video|video/m3'], greaterThan(1));
    expect(
      newKeys[newWay.primary['video|video/o1']],
      remoteSeriesNaturalKey('Shelf', 'collection'),
      reason: '已有真合集主归属的集不被叠加改走',
    );
    expect(
      newWay.virtualCollections.values.map((c) => c.name).toSet(),
      <String>{'Alpha', 'Removed', 'Other'},
    );
    // 懒收养不写库：合集与成员行一条没多。
    expect(
      (await lazy.getAllMediaCollections()).map((c) => c.name).toSet(),
      <String>{'Unrelated', 'Manual', 'Unordered', 'Shelf'},
    );
    expect(
      await lazy.getCollectionItems(newWay.primary['video|video/m1']!),
      hasLength(2),
    );
  });

  test('多来源同 id：先到者胜；列式拼接保序', () {
    final RemoteSeriesColumns a =
        RemoteSeriesColumns.fromEntries(const <RemoteSeriesEntry>[
          RemoteSeriesEntry(
            entryKey: 'video/x',
            name: 'S1',
            collectionType: _type,
            sortIndex: 3,
          ),
        ]);
    final RemoteSeriesColumns b = RemoteSeriesColumns(
      entryKeys: const <String>['video/x', 'video/y'],
      names: const <String>['S2', 'S2'],
      types: const <String>[_type, _type],
      sortIndex: Int32List.fromList(<int>[0, 1]),
    );
    final RemoteSeriesOverlay o = buildRemoteSeriesOverlay(
      series: RemoteSeriesColumns.concat(<RemoteSeriesColumns>[a, b]),
      existingPrimary: const <String, int>{},
      existingMemberSortIndex: const <String, int>{},
      collections: const <MediaCollectionRow>[],
      registry: VirtualCollectionRegistry(),
    );
    expect(o.virtualCollections[o.primary['video|video/x']]!.name, 'S1');
    expect(o.memberSortIndex['video|video/x'], 3);
    expect(o.virtualCollections[o.primary['video|video/y']]!.name, 'S2');
  });

  test('虚拟 id 跨次叠加稳定；后台种子区间与主 isolate 的分配不相交', () {
    final VirtualCollectionRegistry main = VirtualCollectionRegistry();
    final MediaCollectionRow alpha = main.rowFor('Alpha', _type);
    final VirtualCollectionSeed seed = main.reserve(4);
    final VirtualCollectionRegistry bg = VirtualCollectionRegistry.seeded(seed);
    expect(bg.rowFor('Alpha', _type).id, alpha.id);
    final int fresh = bg.rowFor('Beta', _type).id;
    expect(main.rowFor('Gamma', _type).id, isNot(fresh));
    expect(fresh, lessThan(alpha.id));
  });

  group('物化与写入口', () {
    late FushiDatabase db;
    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      VirtualCollectionRegistry.instance.attachDatabase(() => db);
    });
    tearDown(() => db.close());

    Future<VideoLibraryMembership> overlay(List<RemoteVideoInfo> videos) =>
        loadVideoLibraryMembership(
          db,
          books: const <VideoBookRow>[],
          series: RemoteSeriesColumns.fromVideos(videos),
        );

    test('读路径认负 id：合集行与成员都来自叠加，不落库', () async {
      final VideoLibraryMembership m = await overlay(<RemoteVideoInfo>[
        _ep('video/a2', 'Alpha', 1),
        _ep('video/a1', 'Alpha', 0),
      ]);
      final int id = m.primary['video|video/a1']!;
      expect(id, isNegative);
      expect((await db.getMediaCollectionById(id))!.name, 'Alpha');
      expect(
        (await db.getCollectionItems(id)).map((i) => i.entryKey).toList(),
        <String>['video/a1', 'video/a2'],
      );
      expect(await db.getAllMediaCollections(), isEmpty);
    });

    test('用户写入虚拟合集 → 整部剧物化、成员钉住、写落在真合集上', () async {
      final VideoLibraryMembership m = await overlay(<RemoteVideoInfo>[
        _ep('video/a1', 'Alpha', 0),
        _ep('video/a2', 'Alpha', 1),
      ]);
      final int virtualId = m.primary['video|video/a1']!;
      await db.renameMediaCollection(virtualId, 'Alpha (renamed)');

      final List<MediaCollectionRow> rows = await db.getAllMediaCollections();
      expect(rows.map((c) => c.name), <String>['Alpha (renamed)']);
      final int realId = rows.single.id;
      final List<MediaCollectionItemRow> items = await db.getCollectionItems(
        realId,
      );
      expect(items.map((i) => i.entryKey), <String>['video/a1', 'video/a2']);
      expect(items.every((i) => i.pinnedByUser), isTrue);
      // 同一会话里拿着旧负 id 的页面接着读写都落到真合集上。
      expect((await db.getMediaCollectionById(virtualId))!.id, realId);
      await db.updateMediaCollectionSubtitleLanguage(virtualId, 'ja');
      expect((await db.getMediaCollectionById(realId))!.subtitleLanguage, 'ja');
      expect(await db.getAllMediaCollections(), hasLength(1));
    });

    test('标签 / 隐私写入虚拟合集：键换成真合集 id', () async {
      final VideoLibraryMembership m = await overlay(<RemoteVideoInfo>[
        _ep('video/a1', 'Alpha', 0),
      ]);
      final int virtualId = m.primary['video|video/a1']!;
      await db.setMediaNsfw(
        TagHostKind.collection,
        collectionTagEntryKey(virtualId),
        true,
      );
      final int realId = (await db.getAllMediaCollections()).single.id;
      expect(
        await db.isMediaNsfw(
          TagHostKind.collection,
          collectionTagEntryKey(realId),
        ),
        isTrue,
      );
      expect(await db.nsfwEntryKeys(TagHostKind.collection), <String>{
        collectionTagEntryKey(realId),
      });
    });

    test('删除虚拟合集 → 留下合集级墓碑，之后的叠加不再分组', () async {
      final List<RemoteVideoInfo> catalog = <RemoteVideoInfo>[
        _ep('video/a1', 'Alpha', 0),
      ];
      final VideoLibraryMembership m = await overlay(catalog);
      await db.deleteMediaCollection(m.primary['video|video/a1']!);
      expect(await db.getAllMediaCollections(), isEmpty);
      expect(await db.hasCollectionDeletionTombstone('Alpha', _type), isTrue);
      final VideoLibraryMembership again = await overlay(catalog);
      expect(again.primary.containsKey('video|video/a1'), isFalse);
    });

    test('两个入口同时物化同一部剧：只建一个合集', () async {
      final VideoLibraryMembership m = await overlay(<RemoteVideoInfo>[
        _ep('video/a1', 'Alpha', 0),
      ]);
      final MediaCollectionRow row = m.virtualCollections.values.single;
      final List<MediaCollectionRow?> both =
          await Future.wait(<Future<MediaCollectionRow?>>[
            materializeRemoteSeriesCollection(db, row),
            materializeRemoteSeriesCollection(db, row),
          ]);
      expect(both[0]!.id, both[1]!.id);
      expect(await db.getAllMediaCollections(), hasLength(1));
    });

    test('下载落地式物化（非用户意图）：用户删过的剧让路', () async {
      await db.upsertCollectionMemberTombstone(
        collectionName: 'Alpha',
        collectionType: _type,
        mediaType: FushiDatabase.collectionTombstoneSentinel,
        entryKey: FushiDatabase.collectionTombstoneSentinel,
        deletedAt: 10,
      );
      final MediaCollectionRow? row = await materializeRemoteSeries(
        db,
        name: 'Alpha',
        collectionType: _type,
        members: const <RemoteSeriesEntry>[
          RemoteSeriesEntry(
            entryKey: 'video/a1',
            name: 'Alpha',
            collectionType: _type,
            sortIndex: 0,
          ),
        ],
        userIntent: false,
      );
      expect(row, isNull);
      expect(await db.getAllMediaCollections(), isEmpty);
    });

    test('同步应用端的裸写入口拒收负 id（上游漏物化即报错，不写脏行）', () async {
      final VideoLibraryMembership m = await overlay(<RemoteVideoInfo>[
        _ep('video/a1', 'Alpha', 0),
      ]);
      final int virtualId = m.primary['video|video/a1']!;
      await expectLater(
        db.deleteMediaCollectionRaw(virtualId),
        throwsArgumentError,
      );
      await expectLater(
        () => db.setCollectionOrderUpdatedAt(virtualId, 1),
        throwsArgumentError,
      );
      expect(await db.getAllMediaCollections(), isEmpty);
    });
  });

  test('没装钩子（纯核心 / 服务端）时用户写入口也拒收负 id', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final Future<int> Function(int)? saved = VirtualCollectionHooks.materialize;
    VirtualCollectionHooks.materialize = null;
    addTearDown(() => VirtualCollectionHooks.materialize = saved);
    await expectLater(db.renameMediaCollection(-3, 'x'), throwsArgumentError);
    await expectLater(db.addTagToCollection(-3, 1), throwsArgumentError);
  });
}
