import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/links/work_graph_store.dart';
import 'package:fushi/src/media/links/work_network_layout.dart';
import 'package:fushi/src/media/links/work_plans.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/links/work_graph.dart';

/// 关系网系列栏（[planWorkNetwork]）：刮削相关作品（已绑定 / 未入库）、沿已绑定
/// 目标展开整条系列、前传 / 续作去重、上限折叠、手动续作 / 外传连接，且系列边
/// 不并作品。
void main() {
  setUpAll(() => LocaleSettings.setLocale(AppLocale.zhCn));

  MediaLinkEndpoint vc(int id) =>
      (kind: MediaLinkKind.videoCollection, key: '$id');
  MediaLinkEndpoint book(String k) => (kind: MediaLinkKind.book, key: k);
  const MediaLinkEndpoint track = (kind: MediaLinkKind.musicTrack, key: 't');

  int nextId = 1;
  CollectionRelationRow rel(
    int collectionId,
    String type, {
    int? target,
    String subjectId = '0',
    String title = '',
    int sortIndex = 0,
    String source = 'anidb',
  }) => CollectionRelationRow(
    id: nextId++,
    collectionId: collectionId,
    relationType: type,
    sortIndex: sortIndex,
    targetCollectionId: target,
    source: source,
    subjectId: subjectId,
    title: title,
  );

  WorkGraphLink link(
    MediaLinkEndpoint from,
    MediaLinkRelation relation,
    MediaLinkEndpoint to, {
    WorkLinkStatus status = WorkLinkStatus.effective,
  }) => WorkGraphLink(
    from: from,
    relation: relation,
    to: to,
    status: status,
    source: MediaLinkSource.manual,
  );

  WorkGraphSnapshot snapshotOf(
    List<WorkGraphLink> links,
    List<CollectionRelationRow> relations,
  ) => WorkGraphSnapshot(
    graph: WorkGraph.build(links: links),
    bookFormatByKey: const <String, String>{},
    series: const <WorkSeriesInfo>[],
    collectionRelations: relations,
  );

  Map<String, WorkNetworkNodeSpec> nodesOf(WorkNetworkPlan plan) =>
      <String, WorkNetworkNodeSpec>{
        for (final WorkNetworkNodeSpec n in plan.nodes) n.id: n,
      };

  List<String> edgesOf(WorkNetworkPlan plan) => <String>[
    for (final WorkNetworkEdgeSpec e in plan.edges)
      '${e.from}>${e.relationKey}>${e.to}${e.suggested ? '?' : ''}',
  ];

  test('刮削相关作品：已绑定沿链展开、未入库画节点不展开、前传反向与续作合一', () {
    final WorkGraphSnapshot s = snapshotOf(
      <WorkGraphLink>[link(track, MediaLinkRelation.themeSong, vc(1))],
      <CollectionRelationRow>[
        rel(1, 'sequel', target: 2, subjectId: '200', title: '2 期'),
        rel(1, 'side_story', subjectId: '300', title: '外传', sortIndex: 1),
        rel(2, 'prequel', target: 1, subjectId: '100', title: '1 期'),
        rel(2, 'sequel', target: 3, subjectId: '400', sortIndex: 1),
        rel(3, 'other', subjectId: '500', title: '总集篇'),
        // AniDB 一边 Side Story、另一边 Parent Story（other）：只留外传。
        rel(3, 'side_story', target: 2, subjectId: '200', sortIndex: 1),
        rel(2, 'other', target: 3, subjectId: '400', sortIndex: 2),
      ],
    );
    final WorkNetworkPlan plan = planWorkNetwork(s, vc(1));
    final Map<String, WorkNetworkNodeSpec> nodes = nodesOf(plan);
    expect(nodes.keys.toSet(), <String>{
      'video_collection-1',
      'music_track-t',
      'video_collection-2',
      'video_collection-3',
      'web-anidb-300',
      'web-anidb-500',
    });
    expect(nodes['video_collection-1']!.role, WorkNetworkRole.member);
    expect(nodes['video_collection-1']!.isSelf, isTrue);
    expect(nodes['music_track-t']!.role, WorkNetworkRole.satellite);
    for (final String id in <String>[
      'video_collection-2',
      'video_collection-3',
      'web-anidb-300',
      'web-anidb-500',
    ]) {
      expect(nodes[id]!.role, WorkNetworkRole.series, reason: id);
    }
    expect(nodes['web-anidb-300']!.target, isNull);
    expect(nodes['web-anidb-300']!.web!.title, '外传');
    expect(nodes['video_collection-2']!.target, vc(2));
    expect(
      edgesOf(plan),
      unorderedEquals(<String>[
        'music_track-t>theme_song>video_collection-1',
        'video_collection-1>series_sequel>video_collection-2',
        'video_collection-1>series_sideStory>web-anidb-300',
        'video_collection-2>series_sequel>video_collection-3',
        'video_collection-3>series_sideStory>video_collection-2',
        'video_collection-3>series_other>web-anidb-500',
      ]),
    );
    final WorkNetworkEdgeSpec sequel = plan.edges.firstWhere(
      (WorkNetworkEdgeSpec e) =>
          e.from == 'video_collection-1' && e.to == 'video_collection-2',
    );
    expect(sequel.directed, isTrue);
    expect(sequel.relation, isNull, reason: '只来自 collection_relations');
    expect(sequel.ids, isEmpty);
  });

  test('超大系列：系列节点上限之外折成「另有 N 部」', () {
    final WorkGraphSnapshot s = snapshotOf(
      <WorkGraphLink>[link(track, MediaLinkRelation.themeSong, vc(1))],
      <CollectionRelationRow>[
        for (int i = 0; i < kWorkNetworkSeriesNodeLimit + 6; i++)
          rel(1, 'movie', subjectId: '$i', title: '剧场版 $i', sortIndex: i),
      ],
    );
    final WorkNetworkPlan plan = planWorkNetwork(s, vc(1));
    final Map<String, WorkNetworkNodeSpec> nodes = nodesOf(plan);
    expect(
      nodes.values.where(
        (WorkNetworkNodeSpec n) => n.role == WorkNetworkRole.series,
      ),
      hasLength(kWorkNetworkSeriesNodeLimit + 1),
    );
    expect(nodes[kWorkNetworkSeriesMoreId]!.moreCount, 6);
    expect(
      plan.edges.where((WorkNetworkEdgeSpec e) => e.seriesKind != null),
      hasLength(kWorkNetworkSeriesNodeLimit),
    );
    final WorkNetworkLayout layout = layoutWorkNetwork(plan);
    expect(
      layout.lanes.map((WorkNetworkLane l) => l.kind.runtimeType),
      contains(WorkNetworkSeriesLane),
    );
    expect(
      layout.nodeOrder.last,
      kWorkNetworkSeriesMoreId,
      reason: '折叠节点在系列栏最后',
    );
  });

  test('合集不在作品图里、只有刮削相关作品时也出网（不是空态）', () {
    final WorkNetworkPlan plan = planWorkNetwork(
      snapshotOf(const <WorkGraphLink>[], <CollectionRelationRow>[
        rel(7, 'sequel', subjectId: '1', title: '续'),
      ]),
      vc(7),
    );
    expect(
      nodesOf(plan).keys,
      unorderedEquals(<String>['video_collection-7', 'web-anidb-1']),
    );
  });

  test('手动续作 / 外传连接：进系列栏、沿已生效的展开、建议态不展开，且不并作品', () {
    final WorkGraphSnapshot s = snapshotOf(<WorkGraphLink>[
      link(book('a'), MediaLinkRelation.sequel, book('b')),
      link(book('b'), MediaLinkRelation.sequel, book('c')),
      link(book('c'), MediaLinkRelation.sideStory, book('fd')),
      link(
        book('b'),
        MediaLinkRelation.sideStory,
        book('d'),
        status: WorkLinkStatus.suggested,
      ),
      link(book('d'), MediaLinkRelation.sequel, book('e')),
      link(book('a'), MediaLinkRelation.adaptation, vc(1)),
    ], const <CollectionRelationRow>[]);
    final WorkGraph g = s.graph;
    expect(
      g.workOf(book('a'))!.contains(book('b')),
      isFalse,
      reason: '系列边不并作品',
    );
    expect(g.workOf(book('a'))!.contains(vc(1)), isTrue);

    final WorkNetworkPlan plan = planWorkNetwork(s, book('a'));
    final Map<String, WorkNetworkNodeSpec> nodes = nodesOf(plan);
    expect(nodes.keys.toSet(), <String>{
      'book-a',
      'video_collection-1',
      'book-b',
      'book-c',
      'book-fd',
      'book-d',
    }, reason: 'd 只经建议态连到，不再往外展开到 e');
    expect(nodes['book-b']!.role, WorkNetworkRole.series);
    expect(
      edgesOf(plan),
      containsAll(<String>[
        'book-a>series_sequel>book-b',
        'book-b>series_sequel>book-c',
        'book-c>series_sideStory>book-fd',
        'book-b>series_sideStory>book-d?',
      ]),
    );
    final WorkNetworkEdgeSpec ab = plan.edges.firstWhere(
      (WorkNetworkEdgeSpec e) => e.from == 'book-a' && e.to == 'book-b',
    );
    expect(ab.relation, MediaLinkRelation.sequel);
    expect(ab.ids, hasLength(1), reason: '可移除 / 否决的落库连接');
  });

  test('同一对节点既有手动续作又有刮削续作：只画一条边、一份节点', () {
    final WorkGraphSnapshot s = snapshotOf(
      <WorkGraphLink>[link(vc(1), MediaLinkRelation.sequel, vc(2))],
      <CollectionRelationRow>[rel(1, 'sequel', target: 2, subjectId: '200')],
    );
    final WorkNetworkPlan plan = planWorkNetwork(s, vc(1));
    expect(plan.nodes, hasLength(2));
    expect(edgesOf(plan), <String>[
      'video_collection-1>series_sequel>video_collection-2',
    ]);
    expect(plan.edges.single.ids, hasLength(1));
  });

  test('系列边的文案', () {
    expect(workSeriesKindLabel(WorkSeriesKind.sequel), '续作');
    expect(workSeriesKindLabel(WorkSeriesKind.sideStory), '外传');
    expect(workSeriesKindLabel(WorkSeriesKind.movie), '剧场版');
    expect(workSeriesKindLabel(WorkSeriesKind.spinOff), '衍生');
    expect(workSeriesKindLabel(WorkSeriesKind.other), '相关');
    expect(
      WorkSeriesKind.fromCollectionRelationWire('future'),
      WorkSeriesKind.other,
    );
  });
}
