import 'dart:async';

import 'package:drift/drift.dart' show ResultSetImplementation;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/links/media_link_entries.dart';
import 'package:fushi/src/media/links/work_graph_store.dart';
import 'package:fushi/src/media/links/work_network_layout.dart';
import 'package:fushi/src/media/links/work_plans.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/links/work_graph.dart';
import 'package:fushi_engine/media/links/work_graph_loader.dart'
    show workGraphSourceTables;

import 'work_links_test_seed.dart';

/// 作品图进程级缓存 + 区块 / 关系网的折叠计算 + 关系网布局。
void main() {
  late FushiDatabase db;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    WorkGraphStore.debounce = const Duration(milliseconds: 10);
  });

  tearDown(() async {
    WorkGraphStore.debounce = const Duration(milliseconds: 400);
    await db.close();
  });

  Future<WorkGraphSnapshot> nextSnapshot(WorkGraphStore store) {
    final Completer<WorkGraphSnapshot> done = Completer<WorkGraphSnapshot>();
    void listener() {
      if (!done.isCompleted) done.complete(store.value!);
    }

    store.addListener(listener);
    return done.future
        .timeout(const Duration(seconds: 10))
        .whenComplete(() => store.removeListener(listener));
  }

  test('后台 isolate 建的图与在调用方建的一致（BUG-5595：建图不占 UI isolate）', () async {
    final WorkLinksSeed seed = await WorkLinksSeed.create(db);
    final WorkGraphSnapshot here = await loadWorkGraphSnapshot(db);
    final bool inline = debugWorkGraphInline;
    debugWorkGraphInline = false;
    addTearDown(() => debugWorkGraphInline = inline);
    final WorkGraphSnapshot off = await loadWorkGraphSnapshotOffUi(db);
    List<List<MediaLinkEndpoint>> works(WorkGraphSnapshot s) =>
        <List<MediaLinkEndpoint>>[
          for (final Work w in s.graph.works) w.members.toList(),
        ];
    expect(works(off), works(here));
    expect(off.graph.workOf(seed.anime)!.members, contains(WorkLinksSeed.vol2));
    expect(off.seriesOf(seed.anime)?.id, here.seriesOf(seed.anime)?.id);
  });

  test('同一个库只有一个持有者；首个监听者挂上才建图，表变更去抖后重建', () async {
    final WorkLinksSeed seed = await WorkLinksSeed.create(db);
    final WorkGraphStore store = WorkGraphStore.of(db);
    expect(identical(store, WorkGraphStore.of(db)), isTrue);
    expect(store.value, isNull, reason: '没有监听者不读库');

    // 一个常驻监听者撑住订阅，另起一次性监听等通知。
    void keepAlive() {}
    store.addListener(keepAlive);
    addTearDown(() => store.removeListener(keepAlive));
    final WorkGraphSnapshot first = await nextSnapshot(store);
    expect(
      first.graph.workOf(seed.anime)!.members,
      contains(WorkLinksSeed.vol2),
    );
    expect(
      first.graph.workOf(WorkLinksSeed.game)!.members,
      hasLength(1),
      reason: '建议态不成边',
    );

    final Future<WorkGraphSnapshot> second = nextSnapshot(store);
    // 一串写入只触发一次重建（去抖）。
    await db.upsertManualMediaLink(
      relation: MediaLinkRelation.sameWork,
      from: seed.anime,
      to: WorkLinksSeed.game,
    );
    await db.addToCollection(seed.novelSeriesId, MediaKind.epub, 'u-none');
    final WorkGraphSnapshot after = await second;
    expect(
      identical(
        after.graph.workOf(WorkLinksSeed.game),
        after.graph.workOf(seed.anime),
      ),
      isTrue,
    );
  });

  test('只写 epub_books（新导入的书）也让作品图失效重建', () async {
    final WorkLinksSeed seed = await WorkLinksSeed.create(db);
    // 成员行先在（书还没导入：uid 换算不出端点），再导入书本身——第二步只写
    // epub_books。
    await db.addToCollection(seed.novelSeriesId, MediaKind.epub, 'u-late');
    final WorkGraphStore store = WorkGraphStore.of(db);
    void keepAlive() {}
    store.addListener(keepAlive);
    addTearDown(() => store.removeListener(keepAlive));
    final WorkGraphSnapshot first = await nextSnapshot(store);
    const MediaLinkEndpoint late = (kind: MediaLinkKind.book, key: 'vol9');
    expect(first.graph.workOf(late), isNull);

    final Future<WorkGraphSnapshot> second = nextSnapshot(store);
    await WorkLinksSeed.insertBook(db, 'vol9', '某小说 9', uid: 'u-late');
    final WorkGraphSnapshot after = await second;
    expect(
      identical(after.graph.workOf(late), after.graph.workOf(seed.anime)),
      isTrue,
      reason: '新书经系列合集并进作品',
    );
    expect(after.seriesOf(late)?.id, seed.novelSeriesId);
  });

  test('缓存失效监听覆盖建图读到的全部表', () {
    expect(
      <String>{
        for (final ResultSetImplementation<dynamic, dynamic> t
            in workGraphSourceTables(db))
          t.entityName,
      },
      <String>{
        'media_links',
        'media_collections',
        'media_collection_items',
        'epub_books',
        'srt_books',
        'video_metadata_works',
        'video_metadata_provider_identities',
      },
    );
  });

  test('快照：分组按书格式分小说 / 漫画；系列合集折叠信息；角标取别的种类', () async {
    final WorkLinksSeed seed = await WorkLinksSeed.create(db);
    final WorkGraphSnapshot s = await loadWorkGraphSnapshot(db);

    expect(s.groupOf(WorkLinksSeed.vol1), WorkMediaGroup.novel);
    expect(s.groupOf(WorkLinksSeed.manga), WorkMediaGroup.manga);
    expect(s.groupOf(seed.anime), WorkMediaGroup.anime);

    final WorkSeriesInfo series = s.seriesOf(WorkLinksSeed.vol2)!;
    expect(series.id, seed.novelSeriesId);
    expect(series.name, '某小说系列');
    expect(series.volumeCount, 3);
    expect(series.openTarget, WorkLinksSeed.vol1);

    expect(s.otherGroupsFor(WorkLinksSeed.vol2), <WorkMediaGroup>[
      WorkMediaGroup.manga,
      WorkMediaGroup.anime,
    ]);
    expect(s.otherGroupsForCollection(seed.novelSeriesId), <WorkMediaGroup>[
      WorkMediaGroup.manga,
      WorkMediaGroup.anime,
    ]);
    expect(
      s.otherGroupsFor(WorkLinksSeed.op),
      isEmpty,
      reason: '主题曲是卫星，不在作品里，没有角标',
    );
  });

  test('区块计划：整部作品按种类分组、系列合集折成一张卡、本条目与所在合集不列出', () async {
    final WorkLinksSeed seed = await WorkLinksSeed.create(db);
    final WorkGraphSnapshot s = await loadWorkGraphSnapshot(db);

    final WorkSectionPlan fromAnime = planWorkSection(
      snapshot: s,
      self: seed.anime,
      confirmed: const [],
    );
    expect(
      <String>[
        for (final g in fromAnime.groups)
          '${g.group.name}:${g.cards.map((c) => c.key).join(',')}',
      ],
      <String>['novel:series-${seed.novelSeriesId}', 'manga:book-m1'],
    );
    expect(fromAnime.groups.first.cards.single.original, isTrue);
    expect(
      <String>[for (final c in fromAnime.satellites) c.key],
      <String>['music_track-t1'],
    );
    expect(fromAnime.networkNodeCount, greaterThanOrEqualTo(2));

    final WorkSectionPlan fromVol2 = planWorkSection(
      snapshot: s,
      self: WorkLinksSeed.vol2,
      confirmed: const [],
    );
    expect(
      <String>[
        for (final g in fromVol2.groups)
          for (final c in g.cards) c.key,
      ],
      <String>[
        'book-m1',
        'video_collection-${collectionTagEntryKey(seed.animeId)}',
      ],
      reason: '本条目所在的系列合集（含其余各卷）不重复列出',
    );

    final WorkSectionPlan fromOp = planWorkSection(
      snapshot: s,
      self: WorkLinksSeed.op,
      confirmed: const [],
    );
    expect(fromOp.isEmpty, isTrue, reason: '没有直接连接时附属物看不到宿主作品');
    expect(fromOp.networkNodeCount, 0);

    final WorkSectionPlan fromOpLinked = planWorkSection(
      snapshot: s,
      self: WorkLinksSeed.op,
      confirmed: await loadMediaLinkViews(db, WorkLinksSeed.op),
    );
    expect(
      <String>[
        for (final g in fromOpLinked.groups)
          '${g.group.name}:${g.cards.map((c) => c.key).join(',')}',
      ],
      <String>[
        'novel:series-${seed.novelSeriesId}',
        'manga:book-m1',
        'anime:video_collection-${collectionTagEntryKey(seed.animeId)}',
      ],
      reason: '主题曲详情页列出它所属的整部作品',
    );
    expect(fromOpLinked.satellites, isEmpty, reason: '本条目自己不再作为卫星出现');
    expect(fromOpLinked.networkEndpoint, isNot(WorkLinksSeed.op));
  });

  test('关系网计划与布局：折叠、建议态、确定性分栏', () async {
    final WorkLinksSeed seed = await WorkLinksSeed.create(db);
    final WorkGraphSnapshot s = await loadWorkGraphSnapshot(db);
    final WorkNetworkPlan plan = planWorkNetwork(s, seed.anime);

    final Map<String, WorkNetworkNodeSpec> nodes =
        <String, WorkNetworkNodeSpec>{for (final n in plan.nodes) n.id: n};
    expect(nodes.keys.toSet(), <String>{
      'series-${seed.novelSeriesId}',
      'book-m1',
      'video_collection-${collectionTagEntryKey(seed.animeId)}',
      'music_track-t1',
      'game-g',
    });
    expect(nodes['game-g']!.role, WorkNetworkRole.suggested);
    expect(nodes['music_track-t1']!.role, WorkNetworkRole.satellite);
    expect(
      nodes['video_collection-${collectionTagEntryKey(seed.animeId)}']!.isSelf,
      isTrue,
    );
    final WorkNetworkEdgeSpec suggested = plan.edges.singleWhere(
      (WorkNetworkEdgeSpec e) => e.suggested,
    );
    expect(suggested.ids, hasLength(1));

    final WorkNetworkLayout a = layoutWorkNetwork(plan);
    final WorkNetworkLayout b = layoutWorkNetwork(
      planWorkNetwork(s, seed.anime),
    );
    expect(a.nodes, b.nodes, reason: '同一份输入布局恒定');
    expect(a.size, b.size);
    expect(a.lanes.first.kind, isA<WorkNetworkSuggestedLane>());
    expect(a.lanes.last.kind, isA<WorkNetworkSatelliteLane>());
    // 标签互不重叠、都在画布内。
    for (int i = 0; i < a.edges.length; i++) {
      expect(
        (Offset.zero & a.size).contains(a.edges[i].label.bottomRight),
        isTrue,
      );
      for (int j = i + 1; j < a.edges.length; j++) {
        expect(a.edges[i].label.overlaps(a.edges[j].label), isFalse);
      }
    }
  });
}
