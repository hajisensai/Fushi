/// 「同一作品」区块与关系网页共用的纯计算：从 [WorkGraphSnapshot] 取出要画的卡 /
/// 节点 / 边（同一系列合集的各卷折成一张卡 / 一个节点），以及两处共用的建议态
/// 确认 / 否决动作。不读库、不碰 widget，单测直接喂快照。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/links/media_link_entries.dart';
import 'package:fushi/src/media/links/work_graph_store.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/links/work_graph.dart';

/// 媒体分组的显示名。
String workMediaGroupLabel(WorkMediaGroup group) => switch (group) {
  WorkMediaGroup.novel => t.media_link_group_novel,
  WorkMediaGroup.manga => t.media_link_group_manga,
  WorkMediaGroup.anime => t.media_link_group_anime,
  WorkMediaGroup.game => t.media_link_group_game,
  WorkMediaGroup.audiobook => t.media_link_group_audiobook,
  WorkMediaGroup.music => t.media_link_group_music,
};

/// 确认一组建议（区块的建议卡与关系网的建议边共用；关系网一条折叠边可能对应
/// 几条落库连接）。
Future<void> confirmMediaLinks(
  FushiDatabase db,
  Iterable<MediaLinkId> ids,
) async {
  for (final MediaLinkId id in ids) {
    await db.confirmMediaLink(id);
  }
}

/// 否决 / 移除一组连接（写墓碑，推断不会再提议这一对）。
///
/// 返回这次移除的撤销凭据（[MediaLinkRemovalUndo.revert]）：误点「移除 AI 关联」/
/// 「移除关联」/「不相关」后能原样恢复（反馈 bkrkQrYhnX：否决墓碑会让推断永不再
/// 提议这一对，没有撤销就只能手动重连）。
Future<MediaLinkRemovalUndo> rejectMediaLinks(
  FushiDatabase db,
  Iterable<MediaLinkId> ids,
) async {
  final List<MediaLinkId> targets = ids.toList(growable: false);
  // 否决管一整对：[FushiDatabase.removeMediaLink] 会顺带把同一对上别的 AI 生效行
  // 也写成墓碑，所以快照取整对的行，而不只是点名的那几条。
  final List<({MediaLinkEndpoint a, MediaLinkEndpoint b})> pairs =
      _mediaLinkPairsOf(targets);
  final Map<MediaLinkId, MediaLinkRow> before = await _mediaLinkRowsOfPairs(
    db,
    pairs,
  );
  for (final MediaLinkId id in targets) {
    await db.removeMediaLink(id);
  }
  final Map<MediaLinkId, MediaLinkRow> after = await _mediaLinkRowsOfPairs(
    db,
    pairs,
  );
  return MediaLinkRemovalUndo._(<MediaLinkRemovalChange>[
    for (final MapEntry<MediaLinkId, MediaLinkRow> e in after.entries)
      if (before[e.key] case final MediaLinkRow previous
          when previous.updatedAt != e.value.updatedAt ||
              previous.deletedAt != e.value.deletedAt)
        (id: e.key, writtenAt: e.value.updatedAt, previous: previous),
  ]);
}

/// 一次移除改动的一行：身份、移除写下的时钟、移除前的整行。
typedef MediaLinkRemovalChange = ({
  MediaLinkId id,
  int writtenAt,
  MediaLinkRow previous,
});

/// [rejectMediaLinks] 的撤销凭据。
final class MediaLinkRemovalUndo {
  const MediaLinkRemovalUndo._(this.changes);

  /// 这次移除实际改动的行（已经是墓碑的行不在里面）。
  final List<MediaLinkRemovalChange> changes;

  /// 没改动任何行（全都早已移除）：没有可撤销的。
  bool get isEmpty => changes.isEmpty;

  /// 把改动的行恢复成移除前的样子（[FushiDatabase.restoreMediaLinkSnapshot]：之后
  /// 又被改过的行不覆盖）。返回恢复了几行。
  Future<int> revert(FushiDatabase db) async {
    int restored = 0;
    for (final MediaLinkRemovalChange c in changes) {
      if (await db.restoreMediaLinkSnapshot(
        c.id,
        writtenAt: c.writtenAt,
        previous: c.previous,
      )) {
        restored++;
      }
    }
    return restored;
  }
}

List<({MediaLinkEndpoint a, MediaLinkEndpoint b})> _mediaLinkPairsOf(
  List<MediaLinkId> ids,
) {
  final Set<String> seen = <String>{};
  final List<({MediaLinkEndpoint a, MediaLinkEndpoint b})> out =
      <({MediaLinkEndpoint a, MediaLinkEndpoint b})>[];
  for (final MediaLinkId id in ids) {
    final MediaLinkKind? fromKind = MediaLinkKind.tryParse(id.fromKind);
    final MediaLinkKind? toKind = MediaLinkKind.tryParse(id.toKind);
    if (fromKind == null || toKind == null) continue;
    final String k1 = '${id.fromKind}\u0000${id.fromKey}';
    final String k2 = '${id.toKind}\u0000${id.toKey}';
    final String pairKey = k1.compareTo(k2) <= 0
        ? '$k1\u0001$k2'
        : '$k2\u0001$k1';
    if (!seen.add(pairKey)) continue;
    out.add((
      a: (kind: fromKind, key: id.fromKey),
      b: (kind: toKind, key: id.toKey),
    ));
  }
  return out;
}

Future<Map<MediaLinkId, MediaLinkRow>> _mediaLinkRowsOfPairs(
  FushiDatabase db,
  List<({MediaLinkEndpoint a, MediaLinkEndpoint b})> pairs,
) async => <MediaLinkId, MediaLinkRow>{
  for (final ({MediaLinkEndpoint a, MediaLinkEndpoint b}) p in pairs)
    for (final MediaLinkRow row in await db.mediaLinksBetween(p.a, p.b))
      mediaLinkIdOf(row): row,
};

/// 一条连接是不是 AI 直接生效的（用户确认后升为 user，就不再算）。
bool mediaLinkIsAiEffective(MediaLinkRow row) =>
    row.deletedAt == null && mediaLinkConfirmerOf(row) == MediaLinkConfirmer.ai;

// ---------------------------------------------------------------------------
// 区块
// ---------------------------------------------------------------------------

/// 区块里的一张卡：一个端点，或折叠起来的一个系列合集。
final class WorkCardSpec {
  WorkCardSpec({
    required this.target,
    required this.group,
    this.series,
    this.original = false,
  });

  /// 解析标题 / 封面、点了打开的端点（折叠合集取 [WorkSeriesInfo.openTarget]）。
  final MediaLinkEndpoint target;
  final WorkMediaGroup group;
  final WorkSeriesInfo? series;

  /// 是作品的原作（或原作所在的系列合集）。
  bool original;

  /// 本条目到这张卡（含折叠进来的各卷）的直接已生效连接：卡片副行的关系名、
  /// 右键「移除关联」、AI 来源标识都从这里取。
  final List<MediaLinkView> direct = <MediaLinkView>[];

  /// 稳定键（widget key / 去重）。
  String get key => series != null
      ? 'series-${series!.id}'
      : '${target.kind.dbValue}-${target.key}';
}

/// 区块要画的内容。
final class WorkSectionPlan {
  const WorkSectionPlan({
    required this.groups,
    required this.satellites,
    required this.networkEndpoint,
    required this.networkNodeCount,
  });

  /// 作品成员按媒体分组（只含非空组，按 [WorkMediaGroup] 顺序）。
  final List<({WorkMediaGroup group, List<WorkCardSpec> cards})> groups;

  /// 卫星（主题曲 / 原声 / 配音）。
  final List<WorkCardSpec> satellites;

  /// 「关系网」入口打开哪个端点的网（通常是本条目；本条目自己是附属物——如一首
  /// 主题曲——时是它所属的作品）。
  final MediaLinkEndpoint networkEndpoint;

  /// 关系网节点数（作品成员 + 卫星，不含建议态）；≥ 2 才出「关系网」入口。
  final int networkNodeCount;

  bool get isEmpty => groups.isEmpty && satellites.isEmpty;
}

/// 算区块内容。
///
/// - [snapshot] 为 null（首次建图未完成）时只用 [confirmed]（本条目的直接已生效
///   连接）兜底，与旧版区块同内容，不闪空。
/// - 本条目自己、以及它所在的系列合集（含合集的其余各卷）不列出。
/// - 本条目是音乐、自己不在任何多成员作品里，但经卫星关系挂在别的作品上（主题曲详情
///   页），列出那些作品——「这首歌属于哪部作品」。
/// - 直接连接一律能找到落点：图还没跟上（去抖中）的新连接按对端分组补进来。
WorkSectionPlan planWorkSection({
  required WorkGraphSnapshot? snapshot,
  required MediaLinkEndpoint self,
  required List<MediaLinkView> confirmed,
}) {
  final Map<String, WorkCardSpec> memberCards = <String, WorkCardSpec>{};
  final Map<String, WorkCardSpec> satelliteCards = <String, WorkCardSpec>{};
  MediaLinkEndpoint networkEndpoint = self;
  int networkNodeCount = 0;

  final WorkSeriesInfo? ownSeries = snapshot?.seriesOf(self);
  bool excluded(MediaLinkEndpoint e) =>
      e == self || (ownSeries != null && ownSeries.covers(e));

  String keyOf(MediaLinkEndpoint e) {
    final WorkSeriesInfo? series = snapshot?.seriesOf(e);
    return series != null
        ? 'series-${series.id}'
        : '${e.kind.dbValue}-${e.key}';
  }

  WorkMediaGroup groupOf(MediaLinkEndpoint e) =>
      snapshot?.groupOf(e) ?? _fallbackGroupOf(e);

  WorkCardSpec cardFor(Map<String, WorkCardSpec> into, MediaLinkEndpoint e) {
    final WorkSeriesInfo? series = snapshot?.seriesOf(e);
    final MediaLinkEndpoint target = series?.openTarget ?? e;
    return into.putIfAbsent(
      keyOf(e),
      () =>
          WorkCardSpec(target: target, group: groupOf(target), series: series),
    );
  }

  if (snapshot != null) {
    final WorkGraph graph = snapshot.graph;
    final Work? own = graph.workOf(self);
    final List<Work> works = <Work>[?own];
    bool showNetwork = true;
    if (mediaLinkIsMusicKind(self.kind) &&
        (own == null || own.members.length < 2)) {
      // 附属物视角（主题曲 / 原声详情页）：经已生效卫星关系挂到的作品。音乐自己的
      // 「网」会把它挂的动画算成它的卫星（方向反了），没有宿主作品时不出网。
      final List<Work> hosts = <Work>[];
      for (final MediaLinkView v in confirmed) {
        final MediaLinkRelation? r = v.relation;
        if (r == null || !workSatelliteRelations.contains(r)) continue;
        final Work? host = graph.workOf(v.other.endpoint);
        if (host != null &&
            !identical(host, own) &&
            !hosts.any((Work w) => identical(w, host))) {
          hosts.add(host);
        }
      }
      if (hosts.isNotEmpty) {
        networkEndpoint = hosts.first.identity;
      } else {
        showNetwork = false;
      }
      works.addAll(hosts);
    }
    for (final Work work in works) {
      for (final MediaLinkEndpoint m in work.members) {
        if (excluded(m)) continue;
        final WorkCardSpec card = cardFor(memberCards, m);
        if (work.original == m) card.original = true;
      }
    }
    final WorkNetwork? network = showNetwork
        ? graph.networkOf(networkEndpoint)
        : null;
    if (network != null) {
      networkNodeCount = network.nodes.length;
      for (final WorkNetworkNode n in network.nodes) {
        if (n.role != WorkNetworkRole.satellite || excluded(n.endpoint)) {
          continue;
        }
        if (memberCards.containsKey(keyOf(n.endpoint))) continue;
        cardFor(satelliteCards, n.endpoint);
      }
    }
  }

  // 系列栏的相关作品（刮削的续作 / 前传…）也算关系网节点：只有一部动画、没有
  // 跨媒体连接的合集，有系列关系就该出「关系网」入口。
  if (snapshot != null) {
    final Iterable<MediaLinkEndpoint> owners =
        snapshot.graph.workOf(networkEndpoint)?.members ??
        <MediaLinkEndpoint>[networkEndpoint];
    for (final MediaLinkEndpoint m in owners) {
      networkNodeCount += snapshot.seriesRelationsFrom(m).length;
    }
    if (networkNodeCount > 0 &&
        snapshot.graph.workOf(networkEndpoint) == null) {
      networkNodeCount += 1; // 本条目自己
    }
    for (final MediaLinkEndpoint m in owners) {
      networkNodeCount += snapshot.graph.seriesLinksOf(m).length;
    }
  }

  // 本条目自己是音乐（附属物）时，它的卫星连接对端就是作品本身，进成员组。
  final bool selfIsSatelliteKind = mediaLinkIsMusicKind(self.kind);
  for (final MediaLinkView v in confirmed) {
    final MediaLinkEndpoint e = v.other.endpoint;
    if (excluded(e)) continue;
    final String key = keyOf(e);
    final WorkCardSpec? existing = memberCards[key] ?? satelliteCards[key];
    if (existing != null) {
      existing.direct.add(v);
      continue;
    }
    // 图还没跟上（去抖中 / 首次建图前）的连接按关系补进对应组。
    final MediaLinkRelation? r = v.relation;
    final bool satellite =
        r != null && workSatelliteRelations.contains(r) && !selfIsSatelliteKind;
    cardFor(satellite ? satelliteCards : memberCards, e).direct.add(v);
  }

  int byOriginalThenKey(WorkCardSpec a, WorkCardSpec b) {
    if (a.original != b.original) return a.original ? -1 : 1;
    return compareMediaLinkEndpoints(a.target, b.target);
  }

  final List<({WorkMediaGroup group, List<WorkCardSpec> cards})> groups =
      <({WorkMediaGroup group, List<WorkCardSpec> cards})>[];
  for (final WorkMediaGroup g in WorkMediaGroup.values) {
    final List<WorkCardSpec> cards = <WorkCardSpec>[
      for (final WorkCardSpec c in memberCards.values)
        if (c.group == g) c,
    ]..sort(byOriginalThenKey);
    if (cards.isNotEmpty) groups.add((group: g, cards: cards));
  }
  final List<WorkCardSpec> satellites = satelliteCards.values.toList()
    ..sort((WorkCardSpec a, WorkCardSpec b) {
      final int byGroup = a.group.index.compareTo(b.group.index);
      return byGroup != 0 ? byGroup : byOriginalThenKey(a, b);
    });
  return WorkSectionPlan(
    groups: groups,
    satellites: satellites,
    networkEndpoint: networkEndpoint,
    networkNodeCount: networkNodeCount,
  );
}

/// 没有快照时的分组（书一律按小说；快照到了会按格式改判）。
WorkMediaGroup _fallbackGroupOf(MediaLinkEndpoint e) => switch (e.kind) {
  MediaLinkKind.book => WorkMediaGroup.novel,
  MediaLinkKind.audiobook => WorkMediaGroup.audiobook,
  MediaLinkKind.videoCollection ||
  MediaLinkKind.videoEpisode => WorkMediaGroup.anime,
  MediaLinkKind.game => WorkMediaGroup.game,
  MediaLinkKind.musicAlbum || MediaLinkKind.musicTrack => WorkMediaGroup.music,
};

// ---------------------------------------------------------------------------
// 关系网
// ---------------------------------------------------------------------------

/// 系列边的种类（`collection_relations.relation_type` 与 `media_links` 的
/// [MediaLinkRelation.sequel] / [MediaLinkRelation.sideStory] 合到一套）。前传一律
/// 反向记成续作（「A 是 B 的前传」=「B 是 A 的续作」），同一对只画一条。
enum WorkSeriesKind {
  /// 前作 → 续作。
  sequel,

  /// 本篇 → 外传 / 番外。
  sideStory,

  /// 本篇 → 剧场版。
  movie,

  /// 本篇 → 衍生作。
  spinOff,

  /// 其余相关（总集篇、另一版本、同一世界观…），无方向。
  other;

  bool get directed => this != WorkSeriesKind.other;

  /// `collection_relations.relation_type` 落库值（未知值归 [other]）；
  /// `prequel` 也映射成 [sequel]，调用方负责把方向反过来。
  static WorkSeriesKind fromCollectionRelationWire(String wire) =>
      switch (wire) {
        'sequel' || 'prequel' => WorkSeriesKind.sequel,
        'side_story' => WorkSeriesKind.sideStory,
        'movie' => WorkSeriesKind.movie,
        'spin_off' => WorkSeriesKind.spinOff,
        _ => WorkSeriesKind.other,
      };

  /// `media_links` 的系列关系 → 种类；不是系列关系返回 null。
  static WorkSeriesKind? ofRelation(MediaLinkRelation relation) =>
      switch (relation) {
        MediaLinkRelation.sequel => WorkSeriesKind.sequel,
        MediaLinkRelation.sideStory => WorkSeriesKind.sideStory,
        _ => null,
      };
}

/// 系列边的显示名（续作 / 外传 / 剧场版 / 衍生 / 相关）。
String workSeriesKindLabel(WorkSeriesKind kind) => switch (kind) {
  WorkSeriesKind.sequel => t.media_link_relation_sequel,
  WorkSeriesKind.sideStory => t.media_link_relation_side_story,
  WorkSeriesKind.movie => t.media_link_series_movie,
  WorkSeriesKind.spinOff => t.media_link_series_spin_off,
  WorkSeriesKind.other => t.media_link_series_related,
};

/// 关系网系列栏最多画几个节点（超大系列——哆啦A梦几十部剧场版——不把画布撑爆）；
/// 超出的折成一个「另有 N 部」节点。
const int kWorkNetworkSeriesNodeLimit = 24;

/// 系列栏「另有 N 部」节点的 id。
const String kWorkNetworkSeriesMoreId = 'series-more';

/// 未入库的相关作品（纯刮削的 `collection_relations` 行）。
final class WorkNetworkWebItem {
  const WorkNetworkWebItem({
    required this.source,
    required this.subjectId,
    required this.title,
    this.coverPath,
  });

  /// 刮削源（`anidb` / `mal` / `tmdb` / 历史 `bangumi`）。
  final String source;
  final String subjectId;
  final String title;

  /// 本机已下载的封面（有才显示；不为画节点去拉远程封面）。
  final String? coverPath;
}

/// 关系网的一个（折叠后的）节点。
final class WorkNetworkNodeSpec {
  WorkNetworkNodeSpec({
    required this.id,
    required this.target,
    required this.group,
    required this.role,
    this.series,
    this.web,
    this.moreCount = 0,
  });

  /// 稳定 id：`series-<合集 id>`、`<种类>-<键>`、未入库的 `web-<源>-<id>`、
  /// 或 [kWorkNetworkSeriesMoreId]。
  final String id;

  /// 本机条目（未入库节点与「另有 N 部」为 null）。
  final MediaLinkEndpoint? target;
  final WorkMediaGroup group;
  WorkNetworkRole role;
  final WorkSeriesInfo? series;

  /// 未入库的相关作品（[target] 为 null 时之一）。
  final WorkNetworkWebItem? web;

  /// 「另有 N 部」节点的 N（其余节点为 0）。
  final int moreCount;
  bool original = false;

  /// 是不是打开关系网的那个条目（或它所在的合集）。
  bool isSelf = false;
}

/// 关系网的一条（折叠后的）边。
final class WorkNetworkEdgeSpec {
  WorkNetworkEdgeSpec({
    required this.from,
    required this.to,
    required this.relation,
    required this.suggested,
    this.seriesKind,
  });

  /// 节点 id；有方向关系是落库方向（原作 → 改编、音乐 → 视频、前作 → 续作、
  /// 本篇 → 外传）。
  final String from;
  final String to;

  /// `media_links` 关系；只来自 `collection_relations` 的系列边为 null。
  final MediaLinkRelation? relation;

  /// 系列边的种类（非系列边为 null）。
  final WorkSeriesKind? seriesKind;

  /// 建议态（虚线、可确认 / 否决）。
  final bool suggested;

  /// 折进这条边的落库连接（确认 / 否决作用于它们全部；纯刮削系列边为空）。
  final List<MediaLinkId> ids = <MediaLinkId>[];

  /// 其中任一条的来源（AI 生效标识等由页面按行再判）。
  final List<String> sources = <String>[];

  bool get directed => seriesKind?.directed ?? relation!.directed;

  /// 标签 / widget key 用的关系名（系列边 `series_<种类>`）。
  String get relationKey =>
      seriesKind != null ? 'series_${seriesKind!.name}' : relation!.dbValue;
}

/// 关系网页要画的内容。
final class WorkNetworkPlan {
  const WorkNetworkPlan({required this.nodes, required this.edges});

  /// 按 id 升序（布局按分组再排）。
  final List<WorkNetworkNodeSpec> nodes;

  /// 按 (from, relation, to, suggested) 升序。
  final List<WorkNetworkEdgeSpec> edges;
}

/// 算 [endpoint] 所在作品的关系网（含建议态）。[endpoint] 不在图里时只有它自己
/// 一个节点（空态），除非它有系列关系。
///
/// 系列栏（[WorkNetworkRole.series]）：从作品成员出发，沿 `media_links` 的续作 /
/// 外传连接与各视频合集的 `collection_relations` 展开——已绑定 / 本机条目继续往外
/// 展开（1 期 → 2 期 → 3 期 → 剧场版整条画全），未入库的相关作品画成节点但不再
/// 展开；新节点超过 [kWorkNetworkSeriesNodeLimit] 折成「另有 N 部」。系列边不改变
/// 作品划分（1 期与 2 期仍是两部作品），已在成员 / 卫星里的节点不重复画。
WorkNetworkPlan planWorkNetwork(
  WorkGraphSnapshot snapshot,
  MediaLinkEndpoint endpoint,
) {
  final WorkNetwork? network = snapshot.graph.networkOf(
    endpoint,
    includeSuggested: true,
  );
  final WorkSeriesInfo? ownSeries = snapshot.seriesOf(endpoint);
  final Map<String, WorkNetworkNodeSpec> nodes =
      <String, WorkNetworkNodeSpec>{};

  int roleRank(WorkNetworkRole r) => switch (r) {
    WorkNetworkRole.member => 3,
    WorkNetworkRole.satellite => 2,
    WorkNetworkRole.series => 1,
    WorkNetworkRole.suggested => 0,
  };

  String nodeIdOf(MediaLinkEndpoint e) {
    final WorkSeriesInfo? series = snapshot.seriesOf(e);
    return series != null
        ? 'series-${series.id}'
        : '${e.kind.dbValue}-${e.key}';
  }

  String addNode(MediaLinkEndpoint e, WorkNetworkRole role) {
    final WorkSeriesInfo? series = snapshot.seriesOf(e);
    final MediaLinkEndpoint target = series?.openTarget ?? e;
    final String id = nodeIdOf(e);
    final WorkNetworkNodeSpec node = nodes.putIfAbsent(
      id,
      () => WorkNetworkNodeSpec(
        id: id,
        target: target,
        group: snapshot.groupOf(target),
        role: role,
        series: series,
      ),
    );
    if (roleRank(role) > roleRank(node.role)) node.role = role;
    if (e == endpoint || (ownSeries != null && identical(series, ownSeries))) {
      node.isSelf = true;
    }
    if (network?.work.original == e) node.original = true;
    return id;
  }

  final Map<String, WorkNetworkEdgeSpec> edges =
      <String, WorkNetworkEdgeSpec>{};

  if (network == null) {
    addNode(endpoint, WorkNetworkRole.member);
  } else {
    for (final WorkNetworkNode n in network.nodes) {
      addNode(n.endpoint, n.role);
    }
    for (final WorkNetworkEdge e in network.edges) {
      String from = nodeIdOf(e.from);
      String to = nodeIdOf(e.to);
      if (from == to) continue; // 同一合集的两卷之间
      if (!e.directed && from.compareTo(to) > 0) {
        final String swap = from;
        from = to;
        to = swap;
      }
      final bool suggested = !e.effective;
      final WorkSeriesKind? kind = WorkSeriesKind.ofRelation(e.relation);
      final String key = kind != null
          ? '$from|series_${kind.name}|$to|$suggested'
          : '$from|${e.relation.dbValue}|$to|$suggested';
      final WorkNetworkEdgeSpec spec = edges.putIfAbsent(
        key,
        () => WorkNetworkEdgeSpec(
          from: from,
          to: to,
          relation: e.relation,
          seriesKind: kind,
          suggested: suggested,
        ),
      );
      spec.ids.add(mediaLinkIdFor(e.relation, e.from, e.to));
      spec.sources.add(e.source);
    }
  }

  _addSeriesSection(
    snapshot: snapshot,
    seeds: network?.work.members ?? <MediaLinkEndpoint>[endpoint],
    nodes: nodes,
    edges: edges,
    nodeIdOf: nodeIdOf,
    addLocalNode: (MediaLinkEndpoint e) => addNode(e, WorkNetworkRole.series),
  );

  final List<String> edgeKeys = edges.keys.toList()..sort();
  final List<WorkNetworkNodeSpec> nodeList = nodes.values.toList()
    ..sort(
      (WorkNetworkNodeSpec a, WorkNetworkNodeSpec b) => a.id.compareTo(b.id),
    );
  return WorkNetworkPlan(
    nodes: nodeList,
    edges: <WorkNetworkEdgeSpec>[for (final String k in edgeKeys) edges[k]!],
  );
}

/// 一条待画的系列边（节点 id 已定）。
typedef _SeriesEdge = ({
  String from,
  String to,
  WorkSeriesKind kind,
  bool suggested,
  MediaLinkId? id,
  String source,
});

/// 系列栏：BFS 沿系列关系展开（见 [planWorkNetwork] 文档）。
void _addSeriesSection({
  required WorkGraphSnapshot snapshot,
  required List<MediaLinkEndpoint> seeds,
  required Map<String, WorkNetworkNodeSpec> nodes,
  required Map<String, WorkNetworkEdgeSpec> edges,
  required String Function(MediaLinkEndpoint e) nodeIdOf,
  required String Function(MediaLinkEndpoint e) addLocalNode,
}) {
  final Set<MediaLinkEndpoint> expanded = <MediaLinkEndpoint>{};
  final List<MediaLinkEndpoint> queue = <MediaLinkEndpoint>[
    ...(seeds.toList()..sort(compareMediaLinkEndpoints)),
  ];
  final Set<String> overflow = <String>{};
  final List<_SeriesEdge> found = <_SeriesEdge>[];
  int added = 0;

  /// 节点已在 / 还放得下就返回 true（放得下的顺手建出来）。
  bool admit(String id, void Function() create) {
    if (nodes.containsKey(id)) return true;
    if (added >= kWorkNetworkSeriesNodeLimit) {
      overflow.add(id);
      return false;
    }
    create();
    added++;
    return true;
  }

  void visitLocal(MediaLinkEndpoint e, {required bool expand}) {
    if (!expand || !expanded.add(e)) return;
    queue.add(e);
  }

  while (queue.isNotEmpty) {
    final MediaLinkEndpoint e = queue.removeAt(0);
    expanded.add(e);
    // 同一节点折进来的端点（系列合集的各卷 / 合集端点）一起展开。
    final WorkSeriesInfo? info = snapshot.seriesOf(e);
    final List<MediaLinkEndpoint> covers = <MediaLinkEndpoint>[
      e,
      if (info != null) ...<MediaLinkEndpoint>[?info.endpoint, ...info.members],
    ];
    final String self = nodeIdOf(e);
    for (final MediaLinkEndpoint c in covers) {
      if (c != e && !expanded.add(c)) continue;
      for (final WorkSeriesLink l in snapshot.graph.seriesLinksOf(c)) {
        final MediaLinkEndpoint other = l.from == c ? l.to : l.from;
        final String otherId = nodeIdOf(other);
        if (otherId == self) continue;
        if (!admit(otherId, () => addLocalNode(other))) continue;
        final bool effective = l.status == WorkLinkStatus.effective;
        found.add((
          from: nodeIdOf(l.from),
          to: nodeIdOf(l.to),
          kind: WorkSeriesKind.ofRelation(l.relation)!,
          suggested: !effective,
          id: mediaLinkIdFor(l.relation, l.from, l.to),
          source: l.source,
        ));
        visitLocal(other, expand: effective);
      }
      // 起点是视频合集或挂在单个视频上的作品（散装电影，v162）；已绑定目标同样
      // 两种，都是可点击的本机节点。
      for (final CollectionRelationRow r in snapshot.seriesRelationsFrom(c)) {
        final MediaLinkEndpoint? target = seriesRelationTargetOf(r);
        final String otherId;
        if (target != null) {
          final MediaLinkEndpoint other = target;
          otherId = nodeIdOf(other);
          if (otherId == self) continue;
          if (!admit(otherId, () => addLocalNode(other))) continue;
          visitLocal(other, expand: true);
        } else {
          otherId = 'web-${r.source}-${r.subjectId}';
          if (!admit(
            otherId,
            () => nodes[otherId] = WorkNetworkNodeSpec(
              id: otherId,
              target: null,
              group: WorkMediaGroup.anime,
              role: WorkNetworkRole.series,
              web: WorkNetworkWebItem(
                source: r.source,
                subjectId: r.subjectId,
                title: r.title,
                coverPath: r.coverPath,
              ),
            ),
          )) {
            continue;
          }
        }
        final bool prequel = r.relationType == 'prequel';
        found.add((
          from: prequel ? otherId : self,
          to: prequel ? self : otherId,
          kind: WorkSeriesKind.fromCollectionRelationWire(r.relationType),
          suggested: false,
          id: null,
          source: r.source,
        ));
      }
    }
  }

  if (overflow.isNotEmpty) {
    nodes[kWorkNetworkSeriesMoreId] = WorkNetworkNodeSpec(
      id: kWorkNetworkSeriesMoreId,
      target: null,
      group: WorkMediaGroup.anime,
      role: WorkNetworkRole.series,
      moreCount: overflow.length,
    );
  }

  // 同一对节点有具体关系（续作 / 外传 / 剧场版 / 衍生）时，「相关」那条不画
  // （AniDB 一边写 Side Story、另一边写 Parent Story → other）。
  final Set<String> specificPairs = <String>{
    for (final _SeriesEdge s in found)
      if (s.kind != WorkSeriesKind.other) _pairKey(s.from, s.to),
  };
  for (final _SeriesEdge s in found) {
    if (s.from == s.to) continue;
    if (s.kind == WorkSeriesKind.other &&
        specificPairs.contains(_pairKey(s.from, s.to))) {
      continue;
    }
    String from = s.from;
    String to = s.to;
    if (!s.kind.directed && from.compareTo(to) > 0) {
      final String swap = from;
      from = to;
      to = swap;
    }
    final String key = '$from|series_${s.kind.name}|$to|${s.suggested}';
    final WorkNetworkEdgeSpec spec = edges.putIfAbsent(
      key,
      () => WorkNetworkEdgeSpec(
        from: from,
        to: to,
        relation: s.id == null
            ? null
            : MediaLinkRelation.tryParse(s.id!.relation),
        seriesKind: s.kind,
        suggested: s.suggested,
      ),
    );
    if (s.id case final MediaLinkId id when !spec.ids.contains(id)) {
      spec.ids.add(id);
      spec.sources.add(s.source);
    }
  }
}

String _pairKey(String a, String b) => a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a';
