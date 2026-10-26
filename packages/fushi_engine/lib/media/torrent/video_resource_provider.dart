import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';

class VideoResourceSearchRequest {
  const VideoResourceSearchRequest({
    this.media,
    this.query,
    this.season,
    this.episode,
    this.page = 1,
    this.limit = 100,
    this.providerInstanceId,
  }) : assert(page > 0),
       assert(limit > 0);

  final VideoMediaReference? media;
  final String? query;
  final int? season;
  final int? episode;
  final int page;
  final int limit;

  /// 只搜 provider 的这一个实例（`rss:<siteId>` 冒号后那段）。订阅检查与重启后
  /// 重解析已经知道结果来自哪个站，没必要把用户配的每个站都再打一遍；null = 全部。
  /// 只有多实例 provider（RSS 搜索站）看它，其余 provider 忽略。
  final String? providerInstanceId;

  String get effectiveQuery => query?.trim().isNotEmpty == true
      ? query!.trim()
      : media?.title.trim() ?? '';

  int? get effectiveSeason => season ?? media?.season;
  int? get effectiveEpisode => episode ?? media?.episode;
}

abstract class VideoResourceCandidate {
  VideoResourceCandidate({
    required this.providerId,
    required this.providerInstanceId,
    required this.remoteId,
    required this.title,
    required this.providerPriority,
    this.infoHash,
    this.sizeBytes,
    this.seeders = 0,
    this.leechers = 0,
    this.completed = 0,
    this.publishedAt,
    this.category,
    this.resolution,
    this.releaseGroup,
    this.trusted = false,
    this.detailsUrl,
    this.magnetUri,
  });

  final String providerId;
  final String providerInstanceId;
  final String remoteId;
  final String title;
  final int providerPriority;
  final String? infoHash;
  final int? sizeBytes;
  final int seeders;
  final int leechers;
  final int completed;
  final DateTime? publishedAt;
  final String? category;
  final String? resolution;
  final String? releaseGroup;
  final bool trusted;
  final String? detailsUrl;

  /// 选择时刻就已在手的持久磁力链接（`magnet:` 前缀），入队时随任务落库
  /// （BUG-1784）：重启/重试解析 payload 不再依赖回索引器重搜——发布名分词
  /// 搜不回或条目被下架都会让「资源还在、钥匙丢了」变成 notFound。只有
  /// 临时 URL（Torznab .torrent 下载链）的 provider 留 null，走重搜兜底。
  final String? magnetUri;

  /// Cross-indexer dedupe uses the info hash; provider-local identity is a
  /// safe fallback when an indexer does not expose one.
  String get identityKey {
    final String hash = infoHash?.trim().toLowerCase() ?? '';
    if (RegExp(r'^[0-9a-f]{40}$').hasMatch(hash) ||
        RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      return 'torrent:$hash';
    }
    return '$providerId:$providerInstanceId:$remoteId';
  }
}

/// 一个资源源在一次搜索里发出的**一个**查询词及其结果（BUG-2794）。
///
/// [failure] 非空 = 这一条查询失败；否则 [itemCount] 是它拿回的条数（0 也是
/// 合法结果，必须能被用户看见——「某站搜了日文原名、0 条」与「某站挂了」
/// 是两件事，混成一个空列表用户只会以为这家没资源）。
class VideoResourceQueryReport {
  const VideoResourceQueryReport({
    required this.query,
    this.itemCount = 0,
    this.failure,
  });

  final String query;
  final int itemCount;
  final ExternalProviderFailure? failure;
}

/// 一个资源源在一次搜索里的回执：发了哪些查询词、各得几条、有没有失败。
class VideoResourceSourceReport {
  VideoResourceSourceReport({
    required this.providerId,
    Iterable<VideoResourceQueryReport> queries =
        const <VideoResourceQueryReport>[],
    this.itemCount = 0,
    Iterable<ExternalProviderFailure> failures =
        const <ExternalProviderFailure>[],
    this.succeeded = false,
  }) : queries = List<VideoResourceQueryReport>.unmodifiable(queries),
       failures = List<ExternalProviderFailure>.unmodifiable(failures);

  final String providerId;
  final List<VideoResourceQueryReport> queries;

  /// 本源（自身去重后）交出的条数；跨源去重前。
  final int itemCount;
  final List<ExternalProviderFailure> failures;

  /// 至少一条查询成功（哪怕 0 条）。
  final bool succeeded;

  /// 一条都没成功且有失败 = 这家这次整体失败。
  bool get failed => !succeeded && failures.isNotEmpty;

  /// 没成功也没失败 = 这家表达不了这条查询、没有参与。
  bool get skipped => !succeeded && failures.isEmpty;
}

/// 带按源回执的资源搜索结果。[ProviderBatchResult] 的子类型，旧调用方照旧只读
/// items / failures；需要逐源展示的调用方（资源搜索页）再读 [sources]。
class VideoResourceSearchResult
    extends ProviderBatchResult<VideoResourceCandidate> {
  VideoResourceSearchResult({
    super.items,
    super.failures,
    super.successfulProviderCount,
    Iterable<VideoResourceSourceReport> sources =
        const <VideoResourceSourceReport>[],
  }) : sources = List<VideoResourceSourceReport>.unmodifiable(sources);

  final List<VideoResourceSourceReport> sources;
}

/// 把单个 provider 的结果归成按源回执。provider 自己给了回执（[result] 是
/// [VideoResourceSearchResult]）就原样用——多实例 provider（RSS 搜索站）一个站
/// 一份、没有站参与时为空；否则按「发了 [fallbackQuery] 这一条」合成一份——
/// Torznab 等外部 provider 不必各自实现回执。
List<VideoResourceSourceReport> videoResourceSourceReportsOf({
  required String providerId,
  required ProviderBatchResult<VideoResourceCandidate> result,
  required String fallbackQuery,
}) {
  if (result is VideoResourceSearchResult) return result.sources;
  return <VideoResourceSourceReport>[
    _syntheticSourceReport(providerId, result, fallbackQuery),
  ];
}

VideoResourceSourceReport _syntheticSourceReport(
  String providerId,
  ProviderBatchResult<VideoResourceCandidate> result,
  String fallbackQuery,
) {
  final bool succeeded = result.successfulProviderCount > 0;
  return VideoResourceSourceReport(
    providerId: providerId,
    queries: <VideoResourceQueryReport>[
      if (succeeded || result.hasFailures)
        VideoResourceQueryReport(
          query: fallbackQuery,
          itemCount: result.items.length,
          failure: succeeded ? null : result.failures.firstOrNull,
        ),
    ],
    itemCount: result.items.length,
    failures: result.failures,
    succeeded: succeeded,
  );
}

abstract interface class VideoResourceProvider {
  String get id;

  /// Lower values run first and win duplicate candidates.
  int get priority;

  /// 本 provider 参与哪些视频域。**空集 = 不限域**（用户自配的 Torznab 索引器
  /// 就是这种：搜什么由他自己填的分类决定，app 无权替他裁；RSS 搜索站也报空集，
  /// 按每个站配置的域在 provider 内部逐站裁）。
  ///
  /// 这里之前不存在——域门控是 `VideoResourceRegistry` 里一行写死的 id 白名单
  /// （torznab 恒参与、某内置源只进动漫）。每加一个
  /// 内置源就得回去改那行 if，而 provider 自己对「我该在哪个域出现」一无所知。
  /// 把它变成 provider 自报的能力，registry 那边的特殊情况就整个消失了。
  Set<VideoDiscoveryCategory> get categories;

  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  );

  /// Resolves a selected candidate to a magnet or validated metainfo payload.
  /// Provider credentials and temporary URLs must not escape through payloads.
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate);

  void close();
}

List<VideoResourceCandidate> deduplicateVideoResources(
  Iterable<VideoResourceCandidate> candidates,
) {
  final Map<String, VideoResourceCandidate> best =
      <String, VideoResourceCandidate>{};
  for (final VideoResourceCandidate candidate in candidates) {
    final VideoResourceCandidate? existing = best[candidate.identityKey];
    if (existing == null ||
        candidate.providerPriority < existing.providerPriority ||
        (candidate.providerPriority == existing.providerPriority &&
            candidate.seeders > existing.seeders)) {
      best[candidate.identityKey] = candidate;
    }
  }
  final List<VideoResourceCandidate> result = best.values.toList();
  result.sort((VideoResourceCandidate a, VideoResourceCandidate b) {
    final int byPriority = a.providerPriority.compareTo(b.providerPriority);
    return byPriority != 0 ? byPriority : b.seeders.compareTo(a.seeders);
  });
  return List<VideoResourceCandidate>.unmodifiable(result);
}

/// 已从仓库移除的内置 BT 搜索站 provider id（2026-10 起不再内置任何搜索站，
/// BT 搜索只走用户自配的 RSS 搜索站与 Torznab）。存量订阅 / 任务的
/// `resourceProvider` 冒号前若是其中之一，订阅服务报「来源已移除」，不迁移。
const Set<String> kRemovedBuiltinVideoResourceProviderIds = <String>{
  'nyaa',
  'apibay',
  'knaben',
};

/// [providerId]（裸 id 或 `<id>:<instance>`）是否属于已移除的内置搜索站。
bool isRemovedBuiltinVideoResourceProvider(String providerId) =>
    kRemovedBuiltinVideoResourceProviderIds.contains(
      providerId.trim().split(':').first.toLowerCase(),
    );

/// provider 是否参与某个域的查询。
///
/// [category] 为 null = 请求没带身份（纯关键词搜索）：此时只有不限域的 provider
/// 参与，与 id 白名单时代的行为逐字一致（那时 `anime` 为 false，动漫专用源同样不进）。
bool videoResourceProviderApplies(
  VideoResourceProvider provider,
  VideoDiscoveryCategory? category,
) =>
    provider.categories.isEmpty ||
    (category != null && provider.categories.contains(category));
