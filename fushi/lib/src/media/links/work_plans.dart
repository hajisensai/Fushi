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
Future<void> rejectMediaLinks(
  FushiDatabase db,
  Iterable<MediaLinkId> ids,
) async {
  for (final MediaLinkId id in ids) {
    await db.removeMediaLink(id);
  }
}

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

/// 关系网的一个（折叠后的）节点。
final class WorkNetworkNodeSpec {
  WorkNetworkNodeSpec({
    required this.id,
    required this.target,
    required this.group,
    required this.role,
    this.series,
  });

  /// 稳定 id：`series-<合集 id>` 或 `<种类>-<键>`。
  final String id;
  final MediaLinkEndpoint target;
  final WorkMediaGroup group;
  WorkNetworkRole role;
  final WorkSeriesInfo? series;
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
  });

  /// 节点 id；有方向关系是落库方向（原作 → 改编、音乐 → 视频）。
  final String from;
  final String to;
  final MediaLinkRelation relation;

  /// 建议态（虚线、可确认 / 否决）。
  final bool suggested;

  /// 折进这条边的落库连接（确认 / 否决作用于它们全部）。
  final List<MediaLinkId> ids = <MediaLinkId>[];

  /// 其中任一条的来源（AI 生效标识等由页面按行再判）。
  final List<String> sources = <String>[];

  bool get directed => relation.directed;
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
/// 一个节点（空态）。
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
  final Map<MediaLinkEndpoint, String> idOf = <MediaLinkEndpoint, String>{};

  int roleRank(WorkNetworkRole r) => switch (r) {
    WorkNetworkRole.member => 2,
    WorkNetworkRole.satellite => 1,
    WorkNetworkRole.suggested => 0,
  };

  void addNode(MediaLinkEndpoint e, WorkNetworkRole role) {
    final WorkSeriesInfo? series = snapshot.seriesOf(e);
    final MediaLinkEndpoint target = series?.openTarget ?? e;
    final String id = series != null
        ? 'series-${series.id}'
        : '${e.kind.dbValue}-${e.key}';
    idOf[e] = id;
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
  }

  if (network == null) {
    addNode(endpoint, WorkNetworkRole.member);
    return WorkNetworkPlan(
      nodes: nodes.values.toList(),
      edges: const <WorkNetworkEdgeSpec>[],
    );
  }
  for (final WorkNetworkNode n in network.nodes) {
    addNode(n.endpoint, n.role);
  }

  final Map<String, WorkNetworkEdgeSpec> edges =
      <String, WorkNetworkEdgeSpec>{};
  for (final WorkNetworkEdge e in network.edges) {
    String from = idOf[e.from]!;
    String to = idOf[e.to]!;
    if (from == to) continue; // 同一合集的两卷之间
    if (!e.directed && from.compareTo(to) > 0) {
      final String swap = from;
      from = to;
      to = swap;
    }
    final bool suggested = !e.effective;
    final String key = '$from|${e.relation.dbValue}|$to|$suggested';
    final WorkNetworkEdgeSpec spec = edges.putIfAbsent(
      key,
      () => WorkNetworkEdgeSpec(
        from: from,
        to: to,
        relation: e.relation,
        suggested: suggested,
      ),
    );
    spec.ids.add(mediaLinkIdFor(e.relation, e.from, e.to));
    spec.sources.add(e.source);
  }
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
