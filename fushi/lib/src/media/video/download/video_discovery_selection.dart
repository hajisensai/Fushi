/// 视频发现 → 下载 / 订阅的**选择模型**与订阅规则推导。
///
/// 从 `video_discovery_acquisition_dialogs.dart` 抽出：这些类型与纯函数被资源搜索页、
/// 订阅页、首页组合根的提交函数（`video_discovery_submit.dart`）以及 AI 下载流程
/// （`media/video/acquisition/`）共用，不该住在一个 2000 行的页面文件里。页面文件
/// `export` 本文件，既有 import 不受影响。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:fushi_core/fushi_core.dart' show MediaSourceRow;
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/subscription_release_scope.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi/src/media/video/download/video_resource_version_groups.dart';

@immutable
class VideoDiscoveryDownloadSelection {
  const VideoDiscoveryDownloadSelection({
    required this.media,
    required this.resource,
    required this.source,
    required this.subtitlePolicy,
  });

  final VideoMediaReference media;
  final VideoResourceCandidate resource;
  final MediaSourceRow source;
  final VideoDownloadSubtitlePolicy subtitlePolicy;
}

@immutable
class StrictVideoSubscriptionFilter {
  const StrictVideoSubscriptionFilter({
    required this.json,
    required this.releaseGroup,
    required this.resolution,
    required this.summaryParts,
  });

  final String json;
  final String? releaseGroup;
  final String? resolution;
  final List<String> summaryParts;
}

@immutable
class VideoDiscoverySubscriptionSelection {
  const VideoDiscoverySubscriptionSelection({
    required this.download,
    required this.filter,
    this.startAfterEpisode,
    this.batchRelease = false,
  });

  final VideoDiscoveryDownloadSelection download;
  final StrictVideoSubscriptionFilter filter;
  final int? startAfterEpisode;

  /// 用户选中的是整包（合集 / 全集 / 认不出集号的 BD 打包）。
  ///
  /// 宿主据此把订阅建成一次性模式：整包里没有「下一集」可追，按追更建出来的
  /// 规则结构上永远匹配不到任何发布（BUG-2619）。
  final bool batchRelease;
}

/// 从用户选中的 release 提取严格订阅规则。返回 null 表示该 release 没有足够的
/// 版本证据，UI 必须拒绝创建订阅，不能退化成宽松标题订阅。
StrictVideoSubscriptionFilter? deriveStrictVideoSubscriptionFilter(
  VideoResourceCandidate candidate,
) {
  final String provider = candidate.providerId.trim().toLowerCase();
  final String? releaseGroup = _nonEmpty(candidate.releaseGroup);
  final String? resolution =
      _nonEmpty(candidate.resolution) ??
      _firstMatch(candidate.title, RegExp(r'\b(?:2160|1080|720|576|480)p\b'));
  final Map<String, Object> filter = <String, Object>{'strict': true};
  final List<String> summary = <String>[];

  if (releaseGroup != null) {
    filter['releaseGroup'] = releaseGroup;
    summary.add(releaseGroup);
  }
  if (resolution != null) {
    filter['resolution'] = resolution;
    summary.add(resolution);
  }
  if (candidate.category?.trim().isNotEmpty == true) {
    filter['category'] = candidate.category!.trim();
  }

  if (provider == 'nyaa') {
    if (releaseGroup == null || resolution == null) return null;
    // Nyaa 的 trusted 是来源给出的结构化证据；true/false 都按所选 release 精确锁定。
    filter['trusted'] = candidate.trusted;
    summary.add(candidate.trusted ? 'trusted' : 'untrusted');
  } else if (provider == 'torznab') {
    final String? source = _firstMatch(
      candidate.title,
      RegExp(
        r'\b(?:BluRay|WEB[ ._-]?DL|WEB[ ._-]?Rip|HDTV|DVD)\b',
        caseSensitive: false,
      ),
    );
    final String? codec = _firstMatch(
      candidate.title,
      RegExp(
        r'\b(?:AV1|HEVC|H[ ._-]?265|x265|AVC|H[ ._-]?264|x264)\b',
        caseSensitive: false,
      ),
    );
    final String? language = _firstMatch(
      candidate.title,
      RegExp(
        r'\b(?:Dual[ ._-]?Audio|MULTi|Chinese|CHS|CHT|JPN|Japanese|ENG|English)\b',
        caseSensitive: false,
      ),
    );
    if (source != null) {
      filter['source'] = source;
      summary.add(source);
    }
    if (codec != null) {
      filter['codec'] = codec;
      summary.add(codec);
    }
    // 只有标题明确给出语言/音轨证据时才锁定；UI 不推测或声称未选语言。
    if (language != null) {
      filter['language'] = language;
      summary.add(language);
    }
    if (releaseGroup == null &&
        resolution == null &&
        source == null &&
        codec == null &&
        language == null) {
      return null;
    }
  } else {
    return null;
  }

  return StrictVideoSubscriptionFilter(
    json: jsonEncode(filter),
    releaseGroup: releaseGroup,
    resolution: resolution,
    summaryParts: List<String>.unmodifiable(summary),
  );
}

/// 订阅候选列表里的一行：一条**可订阅的规则**，而不是一个发布。
@immutable
class VideoSubscriptionCandidateGroup {
  const VideoSubscriptionCandidateGroup({
    required this.representative,
    required this.filter,
    required this.memberCount,
    required this.episodeNumbers,
    required this.latestPublishedAt,
    this.batchOnly = false,
  });

  /// 用来推出订阅规则、也用来喂下游下载选择的那一条。同组任意一条推出的
  /// filter 都相同（分组键就是它），选谁都不影响订阅本身。
  final VideoResourceCandidate representative;

  /// `null` 表示这一条没有足够的版本证据、根本不能建订阅（UI 照旧显示它并在
  /// 提交时拒绝，不静默吞掉）。
  final StrictVideoSubscriptionFilter? filter;

  /// 这条规则在当前搜索结果里命中了几个发布。
  final int memberCount;

  /// 命中发布里能解析出的集数（升序、去重）；解析不出的不计入。
  final List<int> episodeNumbers;

  /// 这条规则命中的**全部**发布都是整包（合集 / 全集 / 认不出集号的打包）。
  ///
  /// 判据落在组上而不是代表条上：同一条规则底下只要还有一个单集发布，这条规则
  /// 在追更语义下就是活的，代表条恰好是整包不该把它降级成一次性订阅。反过来，
  /// 整组都是整包时，按追更建出来的订阅结构上永不命中（BUG-2619）。
  final bool batchOnly;

  final DateTime? latestPublishedAt;
}

/// 把搜索结果按**订阅生效单位**聚合。
///
/// ## 为什么分组键是 `filter.json` 而不是「字幕组 × 分辨率」
///
/// 用户报障：订阅页搜一部番，列表里是同一个字幕组同一分辨率的十几集，一集一
/// 行，「重复的数据太多了」。根子在于**列表的行单位与订阅的生效单位不一致**：
/// 订阅追踪的是「Erai-raws · 1080p」这条规则，而列表按发布逐条列。
///
/// 于是分组键直接取 [deriveStrictVideoSubscriptionFilter] 的产物 `json`——它
/// 就是「这两个发布订起来是不是同一条」的**定义本身**。自己另写一个
/// 「releaseGroup + resolution」的键看着等价，但 nyaa 还锁 `trusted`、torznab
/// 还锁 source/codec/language，键一旦漏掉其中一维，两条本该分开的规则会被合成
/// 一行，用户订到的和看到的就不是一回事。用定义当键，这种漂移不可能发生。
///
/// 推不出 filter 的条目（版本证据不足）**不聚合**：它们各占一行，保持原样显示，
/// 提交时由既有校验拒绝。把它们并成一坨只会让「为什么订不了」更难看懂。
List<VideoSubscriptionCandidateGroup> groupVideoSubscriptionCandidates(
  List<VideoResourceCandidate> candidates,
) {
  final Map<String, List<VideoResourceCandidate>> byFilter =
      <String, List<VideoResourceCandidate>>{};
  final Map<String, StrictVideoSubscriptionFilter> filters =
      <String, StrictVideoSubscriptionFilter>{};
  final List<VideoSubscriptionCandidateGroup> ungroupable =
      <VideoSubscriptionCandidateGroup>[];
  // 保持来源顺序：Map 的插入序即首次出现序，用户看到的排序不会因聚合而抖动。
  final List<String> order = <String>[];

  for (final VideoResourceCandidate candidate in candidates) {
    final StrictVideoSubscriptionFilter? filter =
        deriveStrictVideoSubscriptionFilter(candidate);
    if (filter == null) {
      ungroupable.add(
        VideoSubscriptionCandidateGroup(
          representative: candidate,
          filter: null,
          memberCount: 1,
          episodeNumbers: const <int>[],
          latestPublishedAt: candidate.publishedAt,
          batchOnly: subscriptionReleaseIsBatch(candidate.title),
        ),
      );
      continue;
    }
    if (!byFilter.containsKey(filter.json)) {
      byFilter[filter.json] = <VideoResourceCandidate>[];
      filters[filter.json] = filter;
      order.add(filter.json);
    }
    byFilter[filter.json]!.add(candidate);
  }

  final List<VideoSubscriptionCandidateGroup> grouped =
      <VideoSubscriptionCandidateGroup>[];
  for (final String key in order) {
    final List<VideoResourceCandidate> members = byFilter[key]!;
    // 代表条：做种最多的那条（最可能拉得动）；并列时取最新发布，再并列取标题
    // 字典序——**全序**，同一份搜索结果每次渲染都得到同一行，不会跳。
    final List<VideoResourceCandidate> sorted =
        List<VideoResourceCandidate>.of(members)
          ..sort((VideoResourceCandidate a, VideoResourceCandidate b) {
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
          });
    final Set<int> episodes = <int>{};
    DateTime? latest;
    bool batchOnly = true;
    for (final VideoResourceCandidate member in members) {
      final int? episode = episodeNumberFromReleaseTitle(member.title);
      if (episode != null) episodes.add(episode);
      if (batchOnly && !subscriptionReleaseIsBatch(member.title)) {
        batchOnly = false;
      }
      final DateTime? published = member.publishedAt;
      if (published != null && (latest == null || published.isAfter(latest))) {
        latest = published;
      }
    }
    grouped.add(
      VideoSubscriptionCandidateGroup(
        representative: sorted.first,
        filter: filters[key],
        memberCount: members.length,
        episodeNumbers: (episodes.toList()..sort()),
        latestPublishedAt: latest,
        batchOnly: batchOnly,
      ),
    );
  }

  // 可订阅的排前面：它们才是这个页面要用户挑的东西。
  return <VideoSubscriptionCandidateGroup>[...grouped, ...ungroupable];
}

// `episodeNumberFromReleaseTitle` 已下沉到 video_resource_version_groups.dart
// （下载模式版本聚类需要），此处 re-export 保源兼容（订阅聚合与测试仍从本文件
// import）。

String videoDiscoverySubscriptionId(VideoMediaReference reference) {
  final String digest = sha256
      .convert(utf8.encode(reference.canonicalIdentityKey))
      .toString()
      .substring(0, 24);
  return 'video-discovery-$digest';
}

String? _nonEmpty(String? value) {
  final String normalized = value?.trim() ?? '';
  return normalized.isEmpty ? null : normalized;
}

String? _firstMatch(String input, RegExp expression) =>
    expression.firstMatch(input)?.group(0)?.trim();
