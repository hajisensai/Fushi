/// 作品层与关系网的计算内核（AI 库管家 spec
/// `docs/specs/2026-11-18-ai-library-curator-design.md` §4.2 / §4.4）。
///
/// 「作品」不建表，是算出来的：作品图谱（`media_links`）的端点外加系列合集带进来的
/// 条目是节点，**已生效**的 `same_work` / `adaptation` 连接与「条目 ∈ 系列合集」是边，
/// 一个连通分量 = 一部作品。`theme_song` / `soundtrack` / `cast` 连的是附属物
/// （OP 单曲、原声 CD、声优），不并进作品——否则一位声优会把半个库连成一部作品——
/// 只在关系网里作为「卫星」画出来。
///
/// 本层是纯函数：输入是普通值对象（不依赖 drift 行类型），读库在
/// `work_graph_loader.dart`。结果只由输入的**集合**决定，与输入顺序无关（各端对同一份
/// 数据算出同一个作品划分与同一组展示属性）。
///
/// 与 `person_identity.dart` 同型：几万节点的并查集，线性时间，留在 Dart（不是 CPU
/// 热点，CLAUDE.md「Rust 胖核心」只管计算型子系统）。
library;

import 'package:fushi_core/fushi_core.dart';

/// 一条连接在作品层眼里的状态。
enum WorkLinkStatus {
  /// 已生效：参与成边（`same_work` / `adaptation`）与卫星判定。
  effective,

  /// 建议态：不成边、不出卫星；关系网 `includeSuggested` 时才带出来。
  suggested,

  /// 已否决 / 已删除：完全不参与。
  rejected;

  /// 同一条连接重复出现时取强者：生效 > 建议 > 否决。
  int get _rank => switch (this) {
    WorkLinkStatus.effective => 2,
    WorkLinkStatus.suggested => 1,
    WorkLinkStatus.rejected => 0,
  };
}

/// 输入：一条连接。无方向关系（`same_work`）的两端不要求调用方预先规范化，
/// [WorkGraph.build] 内部按 [canonicalMediaLinkEndpoints] 排好。
final class WorkGraphLink {
  const WorkGraphLink({
    required this.from,
    required this.relation,
    required this.to,
    required this.status,
    this.source = '',
  });

  final MediaLinkEndpoint from;
  final MediaLinkRelation relation;
  final MediaLinkEndpoint to;
  final WorkLinkStatus status;

  /// `media_links.source`（开放文本，见 `MediaLinkSource`）。
  final String source;
}

/// 输入：一个系列合集（已由调用方判定为「系列」，判定规则见 loader）。
///
/// [endpoint] 是合集本身在图谱里的端点：视频合集有（`MediaLinkKind.videoCollection`），
/// 与每个成员直接相连；书 / 游戏的系列合集没有合集端点，成员之间经一个虚拟节点相连
/// （虚拟节点不出现在任何结果里）。
final class WorkSeriesCollection {
  const WorkSeriesCollection({
    required this.id,
    required this.members,
    this.endpoint,
  });

  /// 合集 id（`MediaCollections.id`），只用来在结果里指认是哪个合集。
  final int id;

  final MediaLinkEndpoint? endpoint;
  final List<MediaLinkEndpoint> members;
}

/// 作品「代表端点」（名字 / 封面从它取）是按哪条规则选出来的（spec §4.2 表）。
enum WorkRepresentativeReason {
  /// 有外部 id 的视频合集端点（取刮削标题）。
  externalVideoCollection,

  /// 成员最多的系列合集（取合集名；端点 = 该合集里最小的端点）。
  largestSeriesCollection,

  /// 兜底：分量内最小端点（取它的标题）。
  smallestEndpoint,
}

/// 作品的代表端点。
typedef WorkRepresentative = ({
  MediaLinkEndpoint endpoint,
  WorkRepresentativeReason reason,

  /// [WorkRepresentativeReason.largestSeriesCollection] 时是那个合集的 id，否则 null。
  int? seriesCollectionId,
});

/// 一部作品（作品图谱的一个连通分量）。
final class Work {
  const Work._({
    required this.identity,
    required this.members,
    required this.original,
    required this.representative,
    required this.seriesCollectionIds,
  });

  /// 身份键：成员按 [compareMediaLinkEndpoints] 最小者。只给界面状态（折叠 / 置顶）
  /// 用，不落库、不进 wire。
  final MediaLinkEndpoint identity;

  /// 全部成员端点，按 [compareMediaLinkEndpoints] 升序。
  final List<MediaLinkEndpoint> members;

  /// 原作：分量内已生效 `adaptation` 边入度为 0 的唯一端点。没有 `adaptation` 边、
  /// 有多个源头、或 `adaptation` 子图有环时为 null（不标，宁缺毋错）。
  final MediaLinkEndpoint? original;

  final WorkRepresentative representative;

  /// 落在本作品里的系列合集 id，升序。
  final List<int> seriesCollectionIds;

  bool contains(MediaLinkEndpoint endpoint) =>
      _binarySearch(members, endpoint) >= 0;
}

/// 关系网里节点的角色（spec §4.4）。
enum WorkNetworkRole {
  /// 作品成员（连通分量里）。
  member,

  /// 卫星：从某个成员一跳、经已生效的 `theme_song` / `soundtrack` / `cast` 连接可达。
  satellite,

  /// 只经建议态连接与成员相连（`includeSuggested` 时才出现，界面画虚线）。
  suggested,
}

/// 关系网节点。
typedef WorkNetworkNode = ({MediaLinkEndpoint endpoint, WorkNetworkRole role});

/// 关系网的一条边（= 一条 `media_links` 连接）。[from] → [to] 是落库方向；
/// 无方向关系（`same_work`）两端已规范化，[directed] 为 false。
final class WorkNetworkEdge {
  const WorkNetworkEdge._({
    required this.from,
    required this.relation,
    required this.to,
    required this.source,
    required this.status,
  });

  final MediaLinkEndpoint from;
  final MediaLinkRelation relation;
  final MediaLinkEndpoint to;
  final String source;

  /// [WorkLinkStatus.effective] 或 [WorkLinkStatus.suggested]（否决的不出现）。
  final WorkLinkStatus status;

  bool get directed => relation.directed;
  bool get effective => status == WorkLinkStatus.effective;
}

/// 一部作品的关系网：成员 + 卫星 + 它们之间的全部连接。
final class WorkNetwork {
  const WorkNetwork._({
    required this.work,
    required this.nodes,
    required this.edges,
  });

  final Work work;

  /// 按 [compareMediaLinkEndpoints] 升序。
  final List<WorkNetworkNode> nodes;

  /// 按 [compareWorkLinks]（from → relation → to）升序。
  final List<WorkNetworkEdge> edges;
}

/// 连接全序：先 from，再关系落库值，再 to。
int compareWorkLinks(
  ({MediaLinkEndpoint from, MediaLinkRelation relation, MediaLinkEndpoint to})
  a,
  ({MediaLinkEndpoint from, MediaLinkRelation relation, MediaLinkEndpoint to})
  b,
) {
  final int byFrom = compareMediaLinkEndpoints(a.from, b.from);
  if (byFrom != 0) return byFrom;
  final int byRelation = a.relation.dbValue.compareTo(b.relation.dbValue);
  if (byRelation != 0) return byRelation;
  return compareMediaLinkEndpoints(a.to, b.to);
}

/// 并进作品的关系（spec §4.2）。
const Set<MediaLinkRelation> workMergingRelations = <MediaLinkRelation>{
  MediaLinkRelation.sameWork,
  MediaLinkRelation.adaptation,
};

/// 出卫星的关系（spec §4.4）。
const Set<MediaLinkRelation> workSatelliteRelations = <MediaLinkRelation>{
  MediaLinkRelation.themeSong,
  MediaLinkRelation.soundtrack,
  MediaLinkRelation.cast,
};

/// 规范化后的一条连接（内部用）。
final class _Link {
  _Link(this.from, this.relation, this.to, this.status, this.source);

  final MediaLinkEndpoint from;
  final MediaLinkRelation relation;
  final MediaLinkEndpoint to;
  final WorkLinkStatus status;
  final String source;

  ({MediaLinkEndpoint from, MediaLinkRelation relation, MediaLinkEndpoint to})
  get id => (from: from, relation: relation, to: to);

  MediaLinkEndpoint otherEnd(MediaLinkEndpoint e) =>
      _sameEndpoint(from, e) ? to : from;
}

/// 作品图：建一次，查多次。数据变了整张重建（spec §4.2：随 `media_links` / 合集
/// 成员表的变更失效重算，不持久化）。
final class WorkGraph {
  WorkGraph._(this._workByEndpoint, this.works, this._adjacency);

  /// 由输入建图。
  ///
  /// [externalIdEndpoints]：有外部 id（刮削身份）的端点，代表端点优先级第一档只看
  /// 其中的视频合集端点。
  factory WorkGraph.build({
    required Iterable<WorkGraphLink> links,
    Iterable<WorkSeriesCollection> seriesCollections =
        const <WorkSeriesCollection>[],
    Set<MediaLinkEndpoint> externalIdEndpoints = const <MediaLinkEndpoint>{},
  }) {
    final List<_Link> normalized = _normalizeLinks(links);
    final List<WorkSeriesCollection> series = <WorkSeriesCollection>[
      for (final WorkSeriesCollection c in seriesCollections)
        if (c.endpoint != null || c.members.isNotEmpty) c,
    ];

    // 节点编号：先收集再排序，编号与输入顺序无关（结果本就只依赖分量，这里只是
    // 让调试输出也稳定）。
    final Set<MediaLinkEndpoint> nodeSet = <MediaLinkEndpoint>{
      for (final _Link l in normalized) ...<MediaLinkEndpoint>[l.from, l.to],
      for (final WorkSeriesCollection c in series) ...<MediaLinkEndpoint>[
        ?c.endpoint,
        ...c.members,
      ],
    };
    final List<MediaLinkEndpoint> nodes = nodeSet.toList()
      ..sort(compareMediaLinkEndpoints);
    final Map<MediaLinkEndpoint, int> indexOf = <MediaLinkEndpoint, int>{
      for (int i = 0; i < nodes.length; i++) nodes[i]: i,
    };

    final _UnionFind uf = _UnionFind(nodes.length);
    for (final _Link l in normalized) {
      if (l.status == WorkLinkStatus.effective &&
          workMergingRelations.contains(l.relation)) {
        uf.union(indexOf[l.from]!, indexOf[l.to]!);
      }
    }
    for (final WorkSeriesCollection c in series) {
      // 视频合集：合集端点与每个成员相连；书 / 游戏：成员经虚拟节点相连——在并查集里
      // 等价于把全部成员并到同一个代表上，虚拟节点不必真的建出来。
      final List<MediaLinkEndpoint> all = <MediaLinkEndpoint>[
        ?c.endpoint,
        ...c.members,
      ];
      final int head = indexOf[all.first]!;
      for (int i = 1; i < all.length; i++) {
        uf.union(head, indexOf[all[i]]!);
      }
    }

    // 分量 → 成员（nodes 已升序，按序追加即升序）。
    final Map<int, List<MediaLinkEndpoint>> membersByRoot =
        <int, List<MediaLinkEndpoint>>{};
    for (int i = 0; i < nodes.length; i++) {
      (membersByRoot[uf.find(i)] ??= <MediaLinkEndpoint>[]).add(nodes[i]);
    }
    final Map<int, List<_Link>> adaptationsByRoot = <int, List<_Link>>{};
    for (final _Link l in normalized) {
      if (l.status == WorkLinkStatus.effective &&
          l.relation == MediaLinkRelation.adaptation) {
        (adaptationsByRoot[uf.find(indexOf[l.from]!)] ??= <_Link>[]).add(l);
      }
    }
    // 原作判定的源头组：只按系列合集成员关系并（不含连接），组号取并查集根，
    // 组内最小端点 = 编号最小者（nodes 已升序）。
    final _UnionFind seriesUf = _UnionFind(nodes.length);
    for (final WorkSeriesCollection c in series) {
      final List<MediaLinkEndpoint> all = <MediaLinkEndpoint>[
        ?c.endpoint,
        ...c.members,
      ];
      final int head = indexOf[all.first]!;
      for (int i = 1; i < all.length; i++) {
        seriesUf.union(head, indexOf[all[i]]!);
      }
    }
    final Map<int, int> groupMinIndex = <int, int>{};
    for (int i = 0; i < nodes.length; i++) {
      groupMinIndex.putIfAbsent(seriesUf.find(i), () => i);
    }
    int groupOf(MediaLinkEndpoint e) => seriesUf.find(indexOf[e]!);
    MediaLinkEndpoint groupMin(int group) => nodes[groupMinIndex[group]!];

    final Map<int, List<WorkSeriesCollection>> seriesByRoot =
        <int, List<WorkSeriesCollection>>{};
    for (final WorkSeriesCollection c in series) {
      final MediaLinkEndpoint any = c.endpoint ?? c.members.first;
      (seriesByRoot[uf.find(indexOf[any]!)] ??= <WorkSeriesCollection>[]).add(
        c,
      );
    }

    final Map<MediaLinkEndpoint, Work> workByEndpoint =
        <MediaLinkEndpoint, Work>{};
    final List<Work> works = <Work>[];
    membersByRoot.forEach((int root, List<MediaLinkEndpoint> members) {
      final List<WorkSeriesCollection> inWork =
          seriesByRoot[root] ?? const <WorkSeriesCollection>[];
      final Work work = Work._(
        identity: members.first,
        members: List<MediaLinkEndpoint>.unmodifiable(members),
        original: _originalOf(
          adaptationsByRoot[root] ?? const <_Link>[],
          groupOf,
          groupMin,
        ),
        representative: _representativeOf(members, inWork, externalIdEndpoints),
        seriesCollectionIds: List<int>.unmodifiable(
          <int>{for (final WorkSeriesCollection c in inWork) c.id}.toList()
            ..sort(),
        ),
      );
      for (final MediaLinkEndpoint m in members) {
        workByEndpoint[m] = work;
      }
      if (members.length >= 2) works.add(work);
    });
    works.sort(
      (Work a, Work b) => compareMediaLinkEndpoints(a.identity, b.identity),
    );

    final Map<MediaLinkEndpoint, List<_Link>> adjacency =
        <MediaLinkEndpoint, List<_Link>>{};
    for (final _Link l in normalized) {
      if (l.status == WorkLinkStatus.rejected) continue;
      (adjacency[l.from] ??= <_Link>[]).add(l);
      (adjacency[l.to] ??= <_Link>[]).add(l);
    }

    return WorkGraph._(
      workByEndpoint,
      List<Work>.unmodifiable(works),
      adjacency,
    );
  }

  final Map<MediaLinkEndpoint, Work> _workByEndpoint;

  /// 非否决连接的邻接表（两个方向都挂）。
  final Map<MediaLinkEndpoint, List<_Link>> _adjacency;

  /// 全部成员数 ≥ 2 的作品，按身份键升序。
  final List<Work> works;

  /// [endpoint] 所在的作品。出现在输入里（任一连接或系列合集）但没有成边的端点
  /// 返回只有它自己的单成员作品；输入里根本没有的端点返回 null。
  Work? workOf(MediaLinkEndpoint endpoint) => _workByEndpoint[endpoint];

  /// [endpoint] 所在作品的关系网（spec §4.4）。输入里没有这个端点返回 null。
  ///
  /// 节点 = 作品成员 + 卫星（任一成员一跳、经已生效的 `theme_song` / `soundtrack` /
  /// `cast` 连接可达）；[includeSuggested] 时再加上经建议态连接与成员相连的另一端
  /// （角色 [WorkNetworkRole.suggested]，已是成员 / 卫星的保持原角色）。
  /// 边 = 两端都在节点集里的全部已生效连接（[includeSuggested] 时再加建议态的）。
  WorkNetwork? networkOf(
    MediaLinkEndpoint endpoint, {
    bool includeSuggested = false,
  }) {
    final Work? work = _workByEndpoint[endpoint];
    if (work == null) return null;
    final Map<MediaLinkEndpoint, WorkNetworkRole> roles =
        <MediaLinkEndpoint, WorkNetworkRole>{
          for (final MediaLinkEndpoint m in work.members)
            m: WorkNetworkRole.member,
        };
    for (final MediaLinkEndpoint m in work.members) {
      for (final _Link l in _adjacency[m] ?? const <_Link>[]) {
        if (l.status == WorkLinkStatus.effective &&
            workSatelliteRelations.contains(l.relation)) {
          roles.putIfAbsent(l.otherEnd(m), () => WorkNetworkRole.satellite);
        }
      }
    }
    if (includeSuggested) {
      for (final MediaLinkEndpoint m in work.members) {
        for (final _Link l in _adjacency[m] ?? const <_Link>[]) {
          if (l.status == WorkLinkStatus.suggested) {
            roles.putIfAbsent(l.otherEnd(m), () => WorkNetworkRole.suggested);
          }
        }
      }
    }

    final List<MediaLinkEndpoint> nodeEndpoints = roles.keys.toList()
      ..sort(compareMediaLinkEndpoints);
    final Map<
      ({
        MediaLinkEndpoint from,
        MediaLinkRelation relation,
        MediaLinkEndpoint to,
      }),
      _Link
    >
    picked =
        <
          ({
            MediaLinkEndpoint from,
            MediaLinkRelation relation,
            MediaLinkEndpoint to,
          }),
          _Link
        >{};
    for (final MediaLinkEndpoint n in nodeEndpoints) {
      for (final _Link l in _adjacency[n] ?? const <_Link>[]) {
        if (l.status == WorkLinkStatus.suggested && !includeSuggested) {
          continue;
        }
        if (!roles.containsKey(l.from) || !roles.containsKey(l.to)) continue;
        picked[l.id] = l;
      }
    }
    final List<_Link> edgeLinks = picked.values.toList()
      ..sort((_Link a, _Link b) => compareWorkLinks(a.id, b.id));

    return WorkNetwork._(
      work: work,
      nodes: List<WorkNetworkNode>.unmodifiable(<WorkNetworkNode>[
        for (final MediaLinkEndpoint e in nodeEndpoints)
          (endpoint: e, role: roles[e]!),
      ]),
      edges: List<WorkNetworkEdge>.unmodifiable(<WorkNetworkEdge>[
        for (final _Link l in edgeLinks)
          WorkNetworkEdge._(
            from: l.from,
            relation: l.relation,
            to: l.to,
            source: l.source,
            status: l.status,
          ),
      ]),
    );
  }
}

/// 规范化无方向关系的两端、丢掉自环、同一条连接（from, relation, to）重复时取
/// 状态强者（同强取来源字典序小者），结果按 [compareWorkLinks] 排序。
List<_Link> _normalizeLinks(Iterable<WorkGraphLink> links) {
  final Map<
    ({
      MediaLinkEndpoint from,
      MediaLinkRelation relation,
      MediaLinkEndpoint to,
    }),
    _Link
  >
  byId =
      <
        ({
          MediaLinkEndpoint from,
          MediaLinkRelation relation,
          MediaLinkEndpoint to,
        }),
        _Link
      >{};
  for (final WorkGraphLink raw in links) {
    if (_sameEndpoint(raw.from, raw.to)) continue;
    final ({MediaLinkEndpoint from, MediaLinkEndpoint to}) c =
        canonicalMediaLinkEndpoints(raw.relation, raw.from, raw.to);
    final _Link link = _Link(
      c.from,
      raw.relation,
      c.to,
      raw.status,
      raw.source,
    );
    final _Link? existing = byId[link.id];
    if (existing == null ||
        link.status._rank > existing.status._rank ||
        (link.status == existing.status &&
            link.source.compareTo(existing.source) < 0)) {
      byId[link.id] = link;
    }
  }
  return byId.values.toList()
    ..sort((_Link a, _Link b) => compareWorkLinks(a.id, b.id));
}

/// 原作：已生效 `adaptation` 子图先按「源头组」收缩——同一个系列合集的成员（视频
/// 合集含合集端点）是一组，不属于任何系列合集的端点各自一组（[groupOf] 给组号）；
/// 收缩后组内的边丢掉，入度为 0 的组唯一时，原作 = 该组的最小端点（[groupMin]，
/// 单端点组就是它自己）。没有边、源头组不唯一、或收缩图有环返回 null。
///
/// 这样「小说第 1、2 卷各连一条 adaptation 到动画」认出同一个源头（小说系列），
/// 而不是判成多源。
MediaLinkEndpoint? _originalOf(
  List<_Link> adaptations,
  int Function(MediaLinkEndpoint endpoint) groupOf,
  MediaLinkEndpoint Function(int group) groupMin,
) {
  final Map<int, int> inDegree = <int, int>{};
  final Map<int, Set<int>> out = <int, Set<int>>{};
  for (final _Link l in adaptations) {
    final int from = groupOf(l.from);
    final int to = groupOf(l.to);
    if (from == to) continue;
    inDegree.putIfAbsent(from, () => 0);
    inDegree.putIfAbsent(to, () => 0);
    if ((out[from] ??= <int>{}).add(to)) inDegree[to] = inDegree[to]! + 1;
  }
  if (inDegree.isEmpty) return null;
  final List<int> sources = <int>[
    for (final MapEntry<int, int> e in inDegree.entries)
      if (e.value == 0) e.key,
  ];
  if (sources.length != 1) return null;
  // Kahn 拓扑排序：排不完说明有环（单源也可能带环，如 S→A→B→A）。
  final Map<int, int> remaining = Map<int, int>.of(inDegree);
  final List<int> queue = <int>[sources.single];
  int visited = 0;
  while (queue.isNotEmpty) {
    final int n = queue.removeLast();
    visited++;
    for (final int next in out[n] ?? const <int>{}) {
      final int left = remaining[next]! - 1;
      remaining[next] = left;
      if (left == 0) queue.add(next);
    }
  }
  return visited == inDegree.length ? groupMin(sources.single) : null;
}

/// 代表端点（spec §4.2 表「名字 / 封面」）：有外部 id 的视频合集端点（多个取最小）
/// → 成员最多的系列合集里的最小端点（同规模取最小端点更小者，再同取 id 小者）
/// → 分量内最小端点。[members] 已升序。
WorkRepresentative _representativeOf(
  List<MediaLinkEndpoint> members,
  List<WorkSeriesCollection> series,
  Set<MediaLinkEndpoint> externalIdEndpoints,
) {
  for (final MediaLinkEndpoint m in members) {
    if (m.kind == MediaLinkKind.videoCollection &&
        externalIdEndpoints.contains(m)) {
      return (
        endpoint: m,
        reason: WorkRepresentativeReason.externalVideoCollection,
        seriesCollectionId: null,
      );
    }
  }
  ({int size, MediaLinkEndpoint smallest, int id})? best;
  for (final WorkSeriesCollection c in series) {
    final Set<MediaLinkEndpoint> distinctMembers = c.members.toSet();
    MediaLinkEndpoint? smallest;
    for (final MediaLinkEndpoint e in <MediaLinkEndpoint>[
      ?c.endpoint,
      ...distinctMembers,
    ]) {
      if (smallest == null || compareMediaLinkEndpoints(e, smallest) < 0) {
        smallest = e;
      }
    }
    final ({int size, MediaLinkEndpoint smallest, int id}) candidate = (
      size: distinctMembers.length,
      smallest: smallest!,
      id: c.id,
    );
    if (best == null ||
        candidate.size > best.size ||
        (candidate.size == best.size &&
            (compareMediaLinkEndpoints(candidate.smallest, best.smallest) < 0 ||
                (_sameEndpoint(candidate.smallest, best.smallest) &&
                    candidate.id < best.id)))) {
      best = candidate;
    }
  }
  if (best != null) {
    return (
      endpoint: best.smallest,
      reason: WorkRepresentativeReason.largestSeriesCollection,
      seriesCollectionId: best.id,
    );
  }
  return (
    endpoint: members.first,
    reason: WorkRepresentativeReason.smallestEndpoint,
    seriesCollectionId: null,
  );
}

bool _sameEndpoint(MediaLinkEndpoint a, MediaLinkEndpoint b) =>
    a.kind == b.kind && a.key == b.key;

int _binarySearch(List<MediaLinkEndpoint> sorted, MediaLinkEndpoint target) {
  int lo = 0;
  int hi = sorted.length - 1;
  while (lo <= hi) {
    final int mid = (lo + hi) >> 1;
    final int c = compareMediaLinkEndpoints(sorted[mid], target);
    if (c == 0) return mid;
    if (c < 0) {
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return -1;
}

/// 路径压缩 + 按秩合并的并查集（同 `person_identity.dart`）。
final class _UnionFind {
  _UnionFind(int n)
    : _parent = List<int>.generate(n, (int i) => i),
      _rank = List<int>.filled(n, 0);

  final List<int> _parent;
  final List<int> _rank;

  int find(int x) {
    int root = x;
    while (_parent[root] != root) {
      root = _parent[root];
    }
    int cur = x;
    while (_parent[cur] != root) {
      final int next = _parent[cur];
      _parent[cur] = root;
      cur = next;
    }
    return root;
  }

  void union(int a, int b) {
    final int ra = find(a);
    final int rb = find(b);
    if (ra == rb) return;
    if (_rank[ra] < _rank[rb]) {
      _parent[ra] = rb;
    } else if (_rank[ra] > _rank[rb]) {
      _parent[rb] = ra;
    } else {
      _parent[rb] = ra;
      _rank[ra]++;
    }
  }
}
