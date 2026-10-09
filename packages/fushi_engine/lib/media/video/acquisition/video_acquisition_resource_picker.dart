/// 资源选择的**确定性规则**：画质过滤、订阅可行性、下载模式选集、「换一个」游标。
///
/// 纯函数，无 IO。输入是 `buildVideoResourceVersionGroups` 已分好的版本卡
/// （组间序 = 相关度 → 做种 → 时间，这里**不重排**），输出是过滤结果与落地计划。
/// AI 不参与这一层；它最多在两张同分辨率、做种相近的卡之间做 tie-break，且那也
/// 是 service 层可选的一步。
library;

import 'package:fushi_engine/media/torrent/anime_release_descriptor.dart';
import 'package:fushi_engine/media/torrent/video_release_language.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/torrent/video_resource_work_match.dart';
import 'package:fushi_engine/media/video/download/video_release_extras.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi_engine/media/video/download/video_discovery_selection.dart';
import 'package:fushi_engine/media/video/download/video_resource_version_groups.dart';

export 'package:fushi_engine/media/torrent/video_resource_work_match.dart'
    show VideoResourceWorkTarget, releaseYearConflicts;

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

/// 画质精确过滤（`quality.matchesResolution`），`any` / `best` 不过滤——`best` 改成按
/// 分辨率降序排在最前，最高档给不出计划（缺集、推不出订阅规则）时逐卡自然落到
/// 次高档，而不是整条流程失败；订阅模式再剔除 `deriveStrictVideoSubscriptionFilter(representative)
/// == null` 的卡；最后按片源 / 码率偏好**稳定**重排（都是 `any` 时保持输入次序）。
///
/// 画质不命中时**不静默降级**：返回 `resolutionMismatch` + 可用分辨率，让对话层去问
/// 「没有 1080p，只有 720p / 2160p，要吗？」。
///
/// [nearestHeight]：只对 `best` 生效——不再「最高优先」，而是「离这一档最近优先」
/// （同距取高）。整套下载里会话画质（如 1080p）一部都没有时退到这里：用户选了
/// 1080p，就该拿 720p 而不是 2160p 的超分（BUG-3067）。[workYear] 供
/// [isSuspectedUpscale] 判「前高清时代作品的 4K」。
VideoAcquisitionResourceOutcome filterResourceGroups(
  List<VideoResourceVersionGroup> groups, {
  required VideoAcquisitionMode mode,
  required VideoAcquisitionQuality quality,
  VideoAcquisitionSourcePref source = VideoAcquisitionSourcePref.any,
  VideoAcquisitionBitratePref bitrate = VideoAcquisitionBitratePref.any,
  int? nearestHeight,
  int? workYear,
}) {
  if (groups.isEmpty) {
    return const VideoAcquisitionResourceOutcome(
      eligible: <VideoResourceVersionGroup>[],
      reason: VideoAcquisitionResourceReason.noCandidates,
    );
  }
  final List<String> available = availableResolutionsOf(groups);
  final bool best = quality == VideoAcquisitionQuality.best;
  final bool highestFirst = best && nearestHeight == null;
  final int? near = best ? nearestHeight : null;
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
      eligible: rankResourceGroups(
        byQuality,
        highestFirst: highestFirst,
        nearestHeight: near,
        workYear: workYear,
        source: source,
        bitrate: bitrate,
      ),
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
    eligible: rankResourceGroups(
      subscribable,
      highestFirst: highestFirst,
      nearestHeight: near,
      workYear: workYear,
      source: source,
      bitrate: bitrate,
    ),
    reason: VideoAcquisitionResourceReason.ok,
    availableResolutions: available,
  );
}

/// 按分辨率（[highestFirst] 取最高 / [nearestHeight] 取最近）→ 保真度 → 片源 →
/// 码率偏好**稳定**重排；全都不要求、也没有低保真卡时原样返回输入次序（= 版本卡的
/// 相关度次序，见 `buildVideoResourceVersionGroups`）。解析不出分辨率的卡、以及
/// [isSuspectedUpscale] 的卡在分辨率排序下都殿后（超分的「4K」不是真 4K）。
///
/// 保真度**总是**生效：超分嫌疑与 DVD 片源的卡排在同档其它卡后面（BUG-3067）——
/// 「1080p」的 DVD 只能是放大出来的。
///
/// 码率拿不到（没有体积、只有整季合集）的卡排在有估值的卡后面，两个方向都一样——
/// 「不知道」既不算大也不算小。
List<VideoResourceVersionGroup> rankResourceGroups(
  List<VideoResourceVersionGroup> groups, {
  bool highestFirst = false,
  int? nearestHeight,
  int? workYear,
  required VideoAcquisitionSourcePref source,
  required VideoAcquisitionBitratePref bitrate,
}) {
  final List<_RankKey> keyed = <_RankKey>[
    for (int i = 0; i < groups.length; i++)
      _rankKeyOf(
        i,
        groups[i],
        highestFirst: highestFirst,
        nearestHeight: nearestHeight,
        workYear: workYear,
        source: source,
        bitrate: bitrate,
      ),
  ];
  keyed.sort((_RankKey a, _RankKey b) {
    final int byHeight = b.height.compareTo(a.height);
    if (byHeight != 0) return byHeight;
    final int byFidelity = b.fidelity.compareTo(a.fidelity);
    if (byFidelity != 0) return byFidelity;
    final int bySource = b.source.compareTo(a.source);
    if (bySource != 0) return bySource;
    final int byBytes = _compareBytes(a.bytes, b.bytes, bitrate);
    if (byBytes != 0) return byBytes;
    return a.index.compareTo(b.index);
  });
  return List<VideoResourceVersionGroup>.unmodifiable(
    <VideoResourceVersionGroup>[for (final entry in keyed) entry.group],
  );
}

typedef _RankKey = ({
  int index,
  VideoResourceVersionGroup group,
  int height,
  int fidelity,
  int source,
  int? bytes,
});

_RankKey _rankKeyOf(
  int index,
  VideoResourceVersionGroup group, {
  required bool highestFirst,
  required int? nearestHeight,
  required int? workYear,
  required VideoAcquisitionSourcePref source,
  required VideoAcquisitionBitratePref bitrate,
}) {
  final bool upscale = isSuspectedUpscale(group, workYear: workYear);
  return (
    index: index,
    group: group,
    height: _heightRank(
      upscale ? null : _heightOf(group),
      highestFirst: highestFirst,
      nearestHeight: nearestHeight,
    ),
    fidelity: upscale || _isDvd(group) ? 0 : 1,
    source: _sourceScore(group, source),
    bytes: bitrate == VideoAcquisitionBitratePref.any
        ? null
        : estimatedBytesPerEpisode(group),
  );
}

/// 分辨率排序键，越大越靠前；不排分辨率时恒 0。未知高度在两种排序下都殿后。
int _heightRank(
  int? height, {
  required bool highestFirst,
  required int? nearestHeight,
}) {
  if (nearestHeight != null) {
    if (height == null) return -(1 << 30);
    // 距离 ×2，同距时更高的那档 +1：1080p 要求下 720p 与 1440p 等距取 1440p。
    final int distance = (height - nearestHeight).abs();
    return -distance * 2 + (height > nearestHeight ? 1 : 0);
  }
  if (highestFirst) return height ?? 0;
  return 0;
}

/// 版本卡的垂直分辨率：结构化字段 / 标题 `1080p` 优先，再退到描述符（认 `4K` /
/// `1920x1080`）。
int? _heightOf(VideoResourceVersionGroup group) =>
    VideoAcquisitionQuality.parseResolutionHeight(group.resolution) ??
    parseAnimeReleaseDescriptor(group.representative.title).resolutionHeight;

bool _isDvd(VideoResourceVersionGroup group) =>
    parseAnimeReleaseDescriptor(group.representative.title).videoSource ==
    AnimeVideoSource.dvd;

/// 前高清时代：此前的作品没有原生 2160p 母带可言，非蓝光片源的 4K 只能是放大。
const int kVideoPreHdEraYear = 2006;

final RegExp _upscaleMarker = RegExp(
  r'upscal\w*|waifu2x|topaz|超分|(?<![a-z])ai[ ._-]?(?:enhanc\w*|remaster\w*|修复|修復|增强|增強)',
  caseSensitive: false,
);

/// 这张卡是不是放大（超分）出来的：标题明写 `upscale` / `超分` / `AI 修复`…，或
/// 前高清时代（[kVideoPreHdEraYear] 之前）作品的 ≥2160p 而片源不是蓝光 / Remux
/// （官方 UHD 蓝光是胶片重扫，算真 4K；网络源的「WEB-4k」老片是平台超分）。
bool isSuspectedUpscale(VideoResourceVersionGroup group, {int? workYear}) {
  final String title = group.representative.title;
  if (_upscaleMarker.hasMatch(title)) return true;
  if (workYear == null || workYear >= kVideoPreHdEraYear) return false;
  final int? height = _heightOf(group);
  if (height == null || height < 2160) return false;
  final AnimeVideoSource source = parseAnimeReleaseDescriptor(
    title,
  ).videoSource;
  return source != AnimeVideoSource.bluRay && source != AnimeVideoSource.remux;
}

int _compareBytes(int? a, int? b, VideoAcquisitionBitratePref bitrate) {
  if (bitrate == VideoAcquisitionBitratePref.any || a == b) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return bitrate == VideoAcquisitionBitratePref.high
      ? b.compareTo(a)
      : a.compareTo(b);
}

/// 片源分数，越大越靠前。判据只用 [parseAnimeReleaseDescriptor]（订阅规则也用它），
/// 不在这里另写一套正则。
int _sourceScore(
  VideoResourceVersionGroup group,
  VideoAcquisitionSourcePref pref,
) {
  if (pref == VideoAcquisitionSourcePref.any) return 0;
  final AnimeVideoSource source = parseAnimeReleaseDescriptor(
    group.representative.title,
  ).videoSource;
  return switch (pref) {
    VideoAcquisitionSourcePref.any => 0,
    VideoAcquisitionSourcePref.bluray =>
      source == AnimeVideoSource.bluRay || source == AnimeVideoSource.remux
          ? 1
          : 0,
    VideoAcquisitionSourcePref.web =>
      source == AnimeVideoSource.webDl || source == AnimeVideoSource.webRip
          ? 1
          : 0,
    VideoAcquisitionSourcePref.best => switch (source) {
      AnimeVideoSource.remux => 6,
      AnimeVideoSource.bluRay => 5,
      AnimeVideoSource.webDl => 4,
      AnimeVideoSource.webRip => 3,
      AnimeVideoSource.television => 2,
      AnimeVideoSource.dvd => 1,
      AnimeVideoSource.unknown => 0,
    },
  };
}

/// 版本卡的片源短标签（`Remux` / `BD` / `WEB-DL` / `WEBRip` / `TV` / `DVD`）；标题
/// 没写片源返回 null。判据同 [_sourceScore]。
String? videoResourceSourceTag(VideoResourceVersionGroup group) =>
    switch (parseAnimeReleaseDescriptor(
      group.representative.title,
    ).videoSource) {
      AnimeVideoSource.remux => 'Remux',
      AnimeVideoSource.bluRay => 'BD',
      AnimeVideoSource.webDl => 'WEB-DL',
      AnimeVideoSource.webRip => 'WEBRip',
      AnimeVideoSource.television => 'TV',
      AnimeVideoSource.dvd => 'DVD',
      AnimeVideoSource.unknown => null,
    };

/// 版本卡的编码短标签（`HEVC 10bit HDR` 这类字面量）；标题里一样都没写返回 null。
/// 同组成员按「组 + 分辨率」归在一起，编码可能各异，只看代表条——与片源标签同口径。
String? videoResourceTraitsTag(VideoResourceVersionGroup group) {
  final AnimeReleaseDescriptor d = parseAnimeReleaseDescriptor(
    group.representative.title,
  );
  final String tag = <String>[
    if (_codecTag(d.videoCodec) case final String codec) codec,
    if (d.bitDepth != null) '${d.bitDepth}bit',
    if (d.dynamicRanges.contains(AnimeDynamicRange.dolbyVision)) 'DV',
    if (d.dynamicRanges.any(_isHdr10Family)) 'HDR',
  ].join(' ');
  return tag.isEmpty ? null : tag;
}

String? _codecTag(AnimeVideoCodec codec) => switch (codec) {
  AnimeVideoCodec.avc => 'AVC',
  AnimeVideoCodec.hevc => 'HEVC',
  AnimeVideoCodec.av1 => 'AV1',
  AnimeVideoCodec.vp9 => 'VP9',
  AnimeVideoCodec.mpeg4 => 'MPEG-4',
  AnimeVideoCodec.unknown => null,
};

bool _isHdr10Family(AnimeDynamicRange range) => switch (range) {
  AnimeDynamicRange.hdr ||
  AnimeDynamicRange.hdr10 ||
  AnimeDynamicRange.hdr10Plus ||
  AnimeDynamicRange.hlg => true,
  AnimeDynamicRange.sdr || AnimeDynamicRange.dolbyVision => false,
};

/// 一个版本的全部可比较事实（与语言无关）：当前版本卡（summary 发言）与候选版本
/// chip（`alt:<i>` 选项）共用这一份，两处说的是同一件事、用同一套字段（BUG-2958）。
Map<String, Object?> videoAcquisitionVersionArgs(
  VideoAcquisitionResourcePlan plan,
) => <String, Object?>{
  'releaseGroup': plan.group.releaseGroup,
  'resolution': plan.group.resolution,
  'source': videoResourceSourceTag(plan.group),
  'traits': videoResourceTraitsTag(plan.group),
  'provider': plan.group.providerId,
  'count': plan.picks.length,
  'batch': plan.usesBatch,
  'seeders': plan.group.bestSeeders,
  'missing': plan.missingEpisodes,
  'startAfterEpisode': plan.startAfterEpisode,
  'bytesPerEpisode': estimatedBytesPerEpisode(plan.group),
};

/// 每集平均体积（码率的代理量）；估不出返回 null。
///
/// 只数**单集**发布：整季合集的体积要除以集数，而合集标题里的集数范围本就不可靠
/// （见 `episodeNumberFromReleaseTitle` 的注释），除错了比不估更糟。电影没有
/// 合集之分，全部成员都算。
int? estimatedBytesPerEpisode(VideoResourceVersionGroup group) {
  int total = 0;
  int count = 0;
  for (final VideoResourceCandidate member in group.members) {
    final int size = member.sizeBytes ?? 0;
    if (size <= 0 || isLikelyBatchVideoRelease(member.title)) continue;
    total += size;
    count++;
  }
  return count == 0 ? null : total ~/ count;
}

/// 一张卡在当前模式 / 集选择下的落地计划；null = 这张卡给不出（进下一张）。
///
/// - movie → 代表条；代表条是多集合集包时标 `usesBatch`（仍整包下载，由整理器
///   改判成剧集整理，BUG-2760）；逐集发布的剧集卡（代表条是单集、组内 ≥2 个
///   不同集号）给不出电影计划 → null，不拿其中一集冒充电影；
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
        return _planMovieDownload(group);
      }
      return _planEpisodesDownload(group, episodes);
  }
}

/// 电影身份下的下载计划（BUG-2760）。
///
/// 电影身份并不保证资源是电影：发现页可能把集数未知的 TV 动画合并到一条电影
/// 身份下，资源搜索于是拿回整季合集包或逐集发布。
/// * 代表条是合集包（`isLikelyBatchVideoRelease`）→ 照旧整包下，但如实标
///   `usesBatch`，摘要说「合集」而不是「一部电影」；落地时整理器按文件名集号
///   改判剧集（`looksLikeEpisodicPack`）。
/// * 代表条本身是某一集、组里还有别的集号 → 这是一张逐集发布的剧集卡，拿一集
///   当电影下只会得到「一部只有第 N 集的电影」，这张卡给不出计划（进下一张）。
/// * 其余（真电影、解析不出集号）→ 代表条，与修前一致。
VideoAcquisitionResourcePlan? _planMovieDownload(
  VideoResourceVersionGroup group,
) {
  final VideoResourceCandidate representative = group.representative;
  if (isLikelyBatchVideoRelease(representative.title)) {
    return VideoAcquisitionResourcePlan(
      group: group,
      picks: <VideoResourceCandidate>[representative],
      usesBatch: true,
    );
  }
  if (episodeNumberFromReleaseTitle(representative.title) != null &&
      group.episodes.length >= 2) {
    return null;
  }
  return VideoAcquisitionResourcePlan(
    group: group,
    picks: <VideoResourceCandidate>[representative],
  );
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

/// 选版本前的候选清洗（全部是**丢弃**，不是排序——留着只会被选中）：
///
/// * [skipExtras]：只有特典的发布（PV / NCOP / 菜单…，判据在引擎
///   `looksLikeExtrasOnlyRelease`）。
/// * [work]：与目标作品身份矛盾的发布（别的年份 / 重制版 / 别的续作序号，判据在
///   [videoResourceWorkMismatch]）。长寿系列的兄弟作品共用几乎全部标题词
///   （哆啦A梦《大雄的恐龙》1980 / 《大雄的新恐龙》2020），不按身份排除就会下错
///   那一部（BUG-3065）。
/// * [originalLanguageOnly]：用户要原语言时，标题明写「只有配音」或「硬字幕」的
///   发布（[releaseIsDubOnly] / [releaseHasBurnedInSubtitles]，BUG-3066）。
///   [workLanguage] 是作品原语言码：国产片的「国语」、粤语片的「粤语」是原音轨，
///   中文作品的「中字」是同语言字幕，都不算不合格；判不出语言时传 null（按外语
///   作品判）。
List<VideoResourceCandidate> cleanResourceCandidates(
  List<VideoResourceCandidate> items, {
  required bool skipExtras,
  VideoResourceWorkTarget? work,
  bool originalLanguageOnly = false,
  String? workLanguage,
}) => <VideoResourceCandidate>[
  for (final VideoResourceCandidate item in items)
    if (!(skipExtras && looksLikeExtrasOnlyRelease(item.title)) &&
        !(work != null &&
            videoResourceWorkMismatch(item.title, work) != null) &&
        !(originalLanguageOnly &&
            (releaseIsDubOnly(item.title, workLanguage: workLanguage) ||
                releaseHasBurnedInSubtitles(
                  item.title,
                  workLanguage: workLanguage,
                ))))
      item,
];

/// 供 tie-break / 摘要用：这张卡的代表条。
VideoResourceCandidate representativeOf(VideoResourceVersionGroup group) =>
    group.representative;
