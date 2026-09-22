/// 资源选择的**确定性规则**：画质过滤、订阅可行性、下载模式选集、「换一个」游标。
///
/// 纯函数，无 IO。输入是 `buildVideoResourceVersionGroups` 已分好的版本卡
/// （组间序 = 相关度 → 做种 → 时间，这里**不重排**），输出是过滤结果与落地计划。
/// AI 不参与这一层；它最多在两张同分辨率、做种相近的卡之间做 tie-break，且那也
/// 是 service 层可选的一步。
library;

import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi/src/media/video/download/video_discovery_selection.dart';
import 'package:fushi/src/media/video/download/video_resource_version_groups.dart';

/// 过滤结果的定性。
enum VideoAcquisitionResourceReason {
  /// 有可用版本卡。
  ok,

  /// 搜索结果为空。
  noCandidates,

  /// 想要的画质一张都没有；[VideoAcquisitionResourceOutcome.availableResolutions]
  /// 列出有的。
  resolutionMismatch,

  /// 订阅模式下没有一张卡推得出严格规则（缺发布组 / 清晰度证据）。
  noSubscribableVersion,
}

class VideoAcquisitionResourceOutcome {
  const VideoAcquisitionResourceOutcome({
    required this.eligible,
    required this.reason,
    this.availableResolutions = const <String>[],
  });

  /// 按画质 / 模式过滤后的版本卡，保持输入顺序。
  final List<VideoResourceVersionGroup> eligible;
  final VideoAcquisitionResourceReason reason;

  /// 结果里出现过的分辨率串（去重，按高度降序；解析不出高度的殿后）。
  final List<String> availableResolutions;
}

/// 画质精确过滤（`quality.matchesResolution`），`any` 不过滤；订阅模式再剔除
/// `deriveStrictVideoSubscriptionFilter(representative) == null` 的卡。
///
/// 画质不命中时**不静默降级**：返回 `resolutionMismatch` + 可用分辨率，让对话层去问
/// 「没有 1080p，只有 720p / 2160p，要吗？」。
VideoAcquisitionResourceOutcome filterResourceGroups(
  List<VideoResourceVersionGroup> groups, {
  required VideoAcquisitionMode mode,
  required VideoAcquisitionQuality quality,
}) {
  if (groups.isEmpty) {
    return const VideoAcquisitionResourceOutcome(
      eligible: <VideoResourceVersionGroup>[],
      reason: VideoAcquisitionResourceReason.noCandidates,
    );
  }
  final List<String> available = availableResolutionsOf(groups);
  final List<VideoResourceVersionGroup> byQuality = <VideoResourceVersionGroup>[
    for (final VideoResourceVersionGroup group in groups)
      if (quality.matchesResolution(group.resolution)) group,
  ];
  if (byQuality.isEmpty) {
    return VideoAcquisitionResourceOutcome(
      eligible: const <VideoResourceVersionGroup>[],
      reason: VideoAcquisitionResourceReason.resolutionMismatch,
      availableResolutions: available,
    );
  }
  if (mode == VideoAcquisitionMode.download) {
    return VideoAcquisitionResourceOutcome(
      eligible: List<VideoResourceVersionGroup>.unmodifiable(byQuality),
      reason: VideoAcquisitionResourceReason.ok,
      availableResolutions: available,
    );
  }
  final List<VideoResourceVersionGroup> subscribable =
      <VideoResourceVersionGroup>[
        for (final VideoResourceVersionGroup group in byQuality)
          if (deriveStrictVideoSubscriptionFilter(group.representative) != null)
            group,
      ];
  if (subscribable.isEmpty) {
    return VideoAcquisitionResourceOutcome(
      eligible: const <VideoResourceVersionGroup>[],
      reason: VideoAcquisitionResourceReason.noSubscribableVersion,
      availableResolutions: available,
    );
  }
  return VideoAcquisitionResourceOutcome(
    eligible: List<VideoResourceVersionGroup>.unmodifiable(subscribable),
    reason: VideoAcquisitionResourceReason.ok,
    availableResolutions: available,
  );
}

/// 一张卡在当前模式 / 集选择下的落地计划；null = 这张卡给不出（进下一张）。
///
/// - movie → 代表条；
/// - 订阅 → 代表条 + [StrictVideoSubscriptionFilter] + `startAfterEpisode = episodes.min`；
/// - 下载 tv：`Single(n)` → `pickResourceVersionCandidate(group, episode: n)`；
///   `Range` → 组内集号落在范围内的成员（同集取代表序最优），缺的集进 `missingEpisodes`；
///   `All` → 有 `isLikelyBatchVideoRelease` 成员则只取做种最多的合集（`usesBatch`），
///   否则所有能解析出集号的成员（同集去重）；结果为空 → null。
VideoAcquisitionResourcePlan? planResourceFromGroup(
  VideoResourceVersionGroup group, {
  required VideoAcquisitionMode mode,
  required VideoMetadataMediaKind kind,
  required VideoAcquisitionEpisodes episodes,
}) {
  final VideoResourceCandidate representative = group.representative;
  switch (mode) {
    case VideoAcquisitionMode.subscribe:
      final StrictVideoSubscriptionFilter? filter =
          deriveStrictVideoSubscriptionFilter(representative);
      if (filter == null) return null;
      final Set<int> known = group.episodes;
      return VideoAcquisitionResourcePlan(
        group: group,
        picks: <VideoResourceCandidate>[representative],
        filter: filter,
        startAfterEpisode: known.isEmpty
            ? null
            : known.reduce((int a, int b) => a < b ? a : b),
      );
    case VideoAcquisitionMode.download:
      if (kind == VideoMetadataMediaKind.movie) {
        return VideoAcquisitionResourcePlan(
          group: group,
          picks: <VideoResourceCandidate>[representative],
        );
      }
      return _planEpisodesDownload(group, episodes);
  }
}

VideoAcquisitionResourcePlan? _planEpisodesDownload(
  VideoResourceVersionGroup group,
  VideoAcquisitionEpisodes episodes,
) {
  switch (episodes) {
    case VideoAcquisitionSingleEpisode(:final int episode):
      final VideoResourceCandidate? hit = pickResourceVersionCandidate(
        group,
        episode: episode,
      );
      if (hit == null) return null;
      return VideoAcquisitionResourcePlan(
        group: group,
        picks: <VideoResourceCandidate>[hit],
      );
    case VideoAcquisitionEpisodeRange(:final int from, :final int to):
      final List<VideoResourceCandidate> picks = <VideoResourceCandidate>[];
      final List<int> missing = <int>[];
      for (int episode = from; episode <= to; episode++) {
        final VideoResourceCandidate? hit = pickResourceVersionCandidate(
          group,
          episode: episode,
        );
        if (hit == null) {
          missing.add(episode);
        } else {
          picks.add(hit);
        }
      }
      if (picks.isEmpty) return null;
      return VideoAcquisitionResourcePlan(
        group: group,
        picks: List<VideoResourceCandidate>.unmodifiable(picks),
        missingEpisodes: List<int>.unmodifiable(missing),
      );
    case VideoAcquisitionAllEpisodes():
      final List<VideoResourceCandidate> batches = <VideoResourceCandidate>[
        for (final VideoResourceCandidate member in group.members)
          if (isLikelyBatchVideoRelease(member.title)) member,
      ];
      if (batches.isNotEmpty) {
        batches.sort(_byRepresentativeOrder);
        return VideoAcquisitionResourcePlan(
          group: group,
          picks: <VideoResourceCandidate>[batches.first],
          usesBatch: true,
        );
      }
      final List<int> known = group.episodes.toList()..sort();
      final List<VideoResourceCandidate> picks = <VideoResourceCandidate>[
        for (final int episode in known)
          pickResourceVersionCandidate(group, episode: episode)!,
      ];
      if (picks.isEmpty) return null;
      return VideoAcquisitionResourcePlan(
        group: group,
        picks: List<VideoResourceCandidate>.unmodifiable(picks),
      );
  }
}

/// 与版本卡「代表条」同一口径：做种最多 → 最新 → 标题（全序，结果稳定）。
int _byRepresentativeOrder(VideoResourceCandidate a, VideoResourceCandidate b) {
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

/// [groups] 里出现过的分辨率串，去重、按高度降序（解析不出的殿后、按字面序）。
///
/// 去重不区分大小写（`1080p` / `1080P` 是同一档，保留首次出现的写法），否则对话层
/// 会给用户列出两个看起来一样的选项。
List<String> availableResolutionsOf(List<VideoResourceVersionGroup> groups) {
  final Set<String> seen = <String>{};
  final List<String> resolutions = <String>[];
  for (final VideoResourceVersionGroup group in groups) {
    final String resolution = group.resolution?.trim() ?? '';
    if (resolution.isEmpty) continue;
    if (seen.add(resolution.toLowerCase())) resolutions.add(resolution);
  }
  resolutions.sort((String a, String b) {
    final int? heightA = VideoAcquisitionQuality.parseResolutionHeight(a);
    final int? heightB = VideoAcquisitionQuality.parseResolutionHeight(b);
    if (heightA != null && heightB != null) {
      final int byHeight = heightB.compareTo(heightA);
      if (byHeight != 0) return byHeight;
    } else if (heightA != heightB) {
      return heightA == null ? 1 : -1;
    }
    return a.compareTo(b);
  });
  return List<String>.unmodifiable(resolutions);
}

/// 供 tie-break / 摘要用：这张卡的代表条。
VideoResourceCandidate representativeOf(VideoResourceVersionGroup group) =>
    group.representative;
