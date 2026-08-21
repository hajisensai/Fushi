/// 下载模式资源候选的「版本」聚类（纯函数，参照 RSS-Subtitle-Manager 的
/// Nyaa 版本选择器）：几十条发布流水账 → 少数几张「发布组 › 清晰度」版本卡。
///
/// 订阅模式已有按订阅生效单位的聚合（`groupVideoSubscriptionCandidates`，
/// BUG-1590）；本模块服务**下载模式**：用户最终要挑的是一条具体发布，聚类只
/// 负责把「哪个组哪个清晰度」这层决策折起来，选组后再展开挑集。
library;

import 'package:fushi/src/media/torrent/video_resource_provider.dart';

/// 从发布标题解析集号（`S01E05` / `Title - 05 [1080p]` 两种主流形态）。
/// 认不出返回 null。纯函数（原居 acquisition dialogs，聚类需要后下沉到此，
/// dialogs 侧 re-export 保源兼容）。
int? episodeNumberFromReleaseTitle(String title) {
  final RegExpMatch? seasonEpisode = RegExp(
    r'\bS\d{1,3}[ ._-]*E(\d{1,4})(?:v\d+)?\b',
    caseSensitive: false,
  ).firstMatch(title);
  if (seasonEpisode != null) return int.tryParse(seasonEpisode.group(1)!);
  final RegExpMatch? anime = RegExp(
    r'(?:^|\s)-\s*(\d{1,4})(?:v\d+)?(?=\s*(?:\[|\(|$))',
    caseSensitive: false,
  ).firstMatch(title);
  return anime == null ? null : int.tryParse(anime.group(1)!);
}

/// 标题开头的发布组标签（`[SubsPlease] xxx` → `SubsPlease`）。
/// candidate.releaseGroup 缺失时的回退；CRC/分辨率不算组名。
String? releaseGroupTagFromTitle(String title) {
  final RegExpMatch? match =
      RegExp(r'^\s*[\[【]([^\]】]{2,30})[\]】]').firstMatch(title);
  if (match == null) return null;
  final String tag = match.group(1)!.trim();
  if (tag.isEmpty) return null;
  if (RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(tag)) return null;
  if (RegExp(r'^\d{3,4}[pP]$').hasMatch(tag)) return null;
  return tag;
}

/// 标题里的清晰度（candidate.resolution 缺失时的回退）。
String? resolutionFromTitle(String title) => RegExp(
      r'\b(2160|1440|1080|720|576|480)[pP]\b',
    ).firstMatch(title)?.group(0)?.toLowerCase();

/// 这条发布是不是整季合集（batch）。判据（保守，全部对应真实发布形态）：
/// - 显式关键词：batch / complete / 合集 / 全集；
/// - 带界定符的集数区间：`[01-12]` / `第01-12话` / `(01~24 Fin)` ——要求区间
///   由 第/括号 引导**或**以 话/集/END/Fin/完 收尾，两端 1..300 且递增，避免
///   把 `2023-08` 日期、分辨率误判成区间。
bool isLikelyBatchVideoRelease(String title) {
  if (RegExp(r'\b(batch|complete)\b', caseSensitive: false).hasMatch(title)) {
    return true;
  }
  if (title.contains('合集') || title.contains('全集')) return true;
  for (final RegExpMatch match in RegExp(
    r'(?:(?<lead>第|\[|\(|【|（)\s*)?(\d{1,3})\s*[-~〜]\s*(\d{1,3})\s*'
    r'(?<tail>话|話|集|END|Fin|完)?',
    caseSensitive: false,
  ).allMatches(title)) {
    if (match.namedGroup('lead') == null && match.namedGroup('tail') == null) {
      continue;
    }
    final int? first = int.tryParse(match.group(2)!);
    final int? last = int.tryParse(match.group(3)!);
    if (first == null || last == null) continue;
    if (first >= 1 && last <= 300 && last > first) return true;
  }
  return false;
}

/// 一张资源「版本卡」：同来源实例、同发布组、同清晰度、同 trusted 的发布集合。
class VideoResourceVersionGroup {
  VideoResourceVersionGroup._({
    required this.key,
    required this.members,
  });

  final String key;

  /// 集号升序（认不出的殿后），同集按发布时间降序。
  final List<VideoResourceCandidate> members;

  String get providerId => members.first.providerId;
  bool get trusted => members.first.trusted;

  String? get releaseGroup =>
      members.first.releaseGroup ??
      releaseGroupTagFromTitle(members.first.title);

  String? get resolution =>
      members.first.resolution ?? resolutionFromTitle(members.first.title);

  /// 卡标题的组成部分（缺段跳过）：组名、清晰度、来源。
  List<String> get labelParts => <String>[
        if (releaseGroup != null) releaseGroup!,
        if (resolution != null) resolution!,
        providerId,
      ];

  Set<int> get episodes => <int>{
        for (final VideoResourceCandidate member in members)
          if (episodeNumberFromReleaseTitle(member.title) != null)
            episodeNumberFromReleaseTitle(member.title)!,
      };

  int get batchCount => members
      .where((VideoResourceCandidate member) =>
          isLikelyBatchVideoRelease(member.title))
      .length;

  DateTime? get latestPublishedAt {
    DateTime? latest;
    for (final VideoResourceCandidate member in members) {
      final DateTime? at = member.publishedAt;
      if (at != null && (latest == null || at.isAfter(latest))) latest = at;
    }
    return latest;
  }

  int get bestSeeders => members.fold(
        0,
        (int best, VideoResourceCandidate member) =>
            member.seeders > best ? member.seeders : best,
      );

  /// 代表条：做种最多 → 最新 → 标题（全序，渲染稳定）。
  VideoResourceCandidate get representative {
    final List<VideoResourceCandidate> sorted =
        List<VideoResourceCandidate>.of(members)..sort(_bySeedersDesc);
    return sorted.first;
  }
}

int _bySeedersDesc(VideoResourceCandidate a, VideoResourceCandidate b) {
  final int bySeeders = b.seeders.compareTo(a.seeders);
  if (bySeeders != 0) return bySeeders;
  final DateTime? pa = a.publishedAt;
  final DateTime? pb = b.publishedAt;
  if (pa != null && pb != null) {
    final int byDate = pb.compareTo(pa);
    if (byDate != 0) return byDate;
  } else if (pa != pb) {
    return pa == null ? 1 : -1;
  }
  return a.title.compareTo(b.title);
}

String _groupKeyOf(VideoResourceCandidate candidate) => <String>[
      candidate.providerId,
      candidate.providerInstanceId,
      (candidate.releaseGroup ??
              releaseGroupTagFromTitle(candidate.title) ??
              '')
          .toLowerCase(),
      (candidate.resolution ?? resolutionFromTitle(candidate.title) ?? '')
          .toLowerCase(),
      candidate.trusted ? 'trusted' : '',
    ].join('\u001f');

int _byEpisodeAsc(VideoResourceCandidate a, VideoResourceCandidate b) {
  final int episodeA = episodeNumberFromReleaseTitle(a.title) ?? (1 << 30);
  final int episodeB = episodeNumberFromReleaseTitle(b.title) ?? (1 << 30);
  if (episodeA != episodeB) return episodeA.compareTo(episodeB);
  return _bySeedersDesc(a, b);
}

/// 聚类 + 排序。组间：最高做种数降序 → 最新发布降序 → key（稳定）。
List<VideoResourceVersionGroup> buildVideoResourceVersionGroups(
  Iterable<VideoResourceCandidate> candidates,
) {
  final Map<String, List<VideoResourceCandidate>> byKey =
      <String, List<VideoResourceCandidate>>{};
  for (final VideoResourceCandidate candidate in candidates) {
    byKey
        .putIfAbsent(_groupKeyOf(candidate), () => <VideoResourceCandidate>[])
        .add(candidate);
  }
  final List<VideoResourceVersionGroup> groups = <VideoResourceVersionGroup>[
    for (final MapEntry<String, List<VideoResourceCandidate>> entry
        in byKey.entries)
      VideoResourceVersionGroup._(
        key: entry.key,
        members: List<VideoResourceCandidate>.unmodifiable(
          entry.value..sort(_byEpisodeAsc),
        ),
      ),
  ];
  groups.sort((VideoResourceVersionGroup a, VideoResourceVersionGroup b) {
    final int bySeeders = b.bestSeeders.compareTo(a.bestSeeders);
    if (bySeeders != 0) return bySeeders;
    final DateTime? pa = a.latestPublishedAt;
    final DateTime? pb = b.latestPublishedAt;
    if (pa != null && pb != null) {
      final int byDate = pb.compareTo(pa);
      if (byDate != 0) return byDate;
    } else if (pa != pb) {
      return pa == null ? 1 : -1;
    }
    return a.key.compareTo(b.key);
  });
  return List<VideoResourceVersionGroup>.unmodifiable(groups);
}

/// 从版本卡解析「用户要的那一集」：
/// - [episode] 非空：集号精确命中 → 该发布（同集多条取代表序最优）；否则 null；
/// - [episode] 为空：组里恰 1 条 → 它；否则 null（UI 展开手选）。
VideoResourceCandidate? pickResourceVersionCandidate(
  VideoResourceVersionGroup group, {
  int? episode,
}) {
  if (episode != null) {
    final List<VideoResourceCandidate> hits = group.members
        .where((VideoResourceCandidate member) =>
            episodeNumberFromReleaseTitle(member.title) == episode)
        .toList()
      ..sort(_bySeedersDesc);
    return hits.isEmpty ? null : hits.first;
  }
  return group.members.length == 1 ? group.members.single : null;
}
