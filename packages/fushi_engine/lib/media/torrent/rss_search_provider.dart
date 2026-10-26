/// 用户自配 RSS 搜索站的网络层与视频资源 provider。
///
/// - [RssSearchClient]：纯搜索 / 解析接口，app 发现页（书 / 有声书 / 漫画 / 游戏）
///   包成 `MediaDiscoverySource` 用；
/// - [RssSearchProvider]：把多个站点接进 [VideoResourceProvider]（视频资源搜索、
///   订阅、重启后重解析），每个站按自己勾的视频域参与，逐站出回执
///   （`providerId` = `rss:<siteId>`）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/anime_release_descriptor.dart';
import 'package:fushi_engine/media/torrent/download_timeouts.dart';
import 'package:fushi_engine/media/torrent/resource_search_queries.dart';
import 'package:fushi_engine/media/torrent/rss_feed_parser.dart';
import 'package:fushi_engine/media/torrent/rss_search_site.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/torrent_download_fetch.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';

export 'package:fushi_engine/media/torrent/rss_feed_parser.dart'
    show RssSearchItem;

/// RSS 搜索站 provider 的裸 id；候选 / 订阅 / 任务的持久化 id 是 `rss:<siteId>`。
const String kRssResourceProviderId = 'rss';

/// 某个站在回执 / 失败 / 持久化里的 provider id。
String rssSiteProviderId(String siteId) => '$kRssResourceProviderId:$siteId';

/// 至少有一个启用、且勾了视频域的站（装配 registry 的判据，与
/// `torznabHasEnabledIndexer` 同一约定：「注册了 = 这台设备上配好了」，零个可用站
/// 时不注册，免得订阅在场校验与 host 能力位把「没配」报成「可用」）。
bool rssHasEnabledVideoSite(Iterable<RssSearchSiteConfig> sites) =>
    sites.any((RssSearchSiteConfig site) => site.appliesToVideo(null));

/// registry 里有没有能搜 [siteId] 这个站的 RSS provider（订阅在场校验用）：
/// [RssSearchProvider] 按它启用且勾了视频域的站判断；id 同为 `rss` 的其它实现
/// 自己管实例，按「在」处理。
bool rssProvidersHaveVideoSite(
  Iterable<VideoResourceProvider> providers,
  String siteId,
) => providers
    .where((VideoResourceProvider p) => p.id == kRssResourceProviderId)
    .any(
      (VideoResourceProvider p) =>
          p is! RssSearchProvider ||
          p.videoSites.any((RssSearchSiteConfig site) => site.id == siteId),
    );

/// RSS 搜索站的 HTTP 层：按模板发请求、解析结果、把选中的条目变成 payload。
class RssSearchClient {
  RssSearchClient({
    http.Client? client,
    this.requestTimeout = kDownloadDiscoveryTimeout,
    bool closesClient = true,
  }) : _client = client ?? http.Client(),
       _closesClient = client == null || closesClient;

  final http.Client _client;
  final bool _closesClient;

  /// 单次请求的整体超时。公共种子站多走代理，取发现链路的统一上限
  /// [kDownloadDiscoveryTimeout]（不是 Torznab 那个面向自建索引器的 20 s）。
  final Duration requestTimeout;

  /// 搜一个站的一页。[page] > 1 而模板没有 `{page}` 时直接返回空（翻到底了，
  /// 不把第一页再拉一遍当第二页）。网络错误 / 非 2xx / 不是 RSS 一律抛
  /// [ExternalProviderFailure]（`providerId` = `rss:<siteId>`），不吞成空列表。
  Future<List<RssSearchItem>> searchSite(
    RssSearchSiteConfig site,
    String query, {
    int page = 1,
  }) async {
    if (page <= 0) throw ArgumentError.value(page, 'page');
    if (page > 1 && !site.supportsPaging) return const <RssSearchItem>[];
    final String providerId = rssSiteProviderId(site.id);
    try {
      final http.Response response = await _client
          .get(site.buildSearchUri(query, page: page))
          .timeout(requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw providerHttpStatusFailure(
          providerId: providerId,
          operation: 'search',
          status: response.statusCode,
          headers: response.headers,
        );
      }
      return parseRssSearchFeed(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
    } on Object catch (error) {
      throw ExternalProviderFailure.fromException(
        providerId: providerId,
        operation: 'search',
        error: error,
      );
    }
  }

  /// 条目 → payload：有磁链直接用（与条目 info hash 复核），否则下载 `.torrent`
  /// 并校验（重定向安全检查 / 体积上限 / hash 复核与 Torznab 同一份实现）。
  Future<TorrentAddPayload> resolveItem(
    RssSearchSiteConfig site,
    RssSearchItem item,
  ) {
    final String providerId = rssSiteProviderId(site.id);
    final String? magnet = item.magnetUri;
    if (magnet != null && magnet.toLowerCase().startsWith('magnet:')) {
      return Future<TorrentAddPayload>.sync(
        () => magnetPayloadForCandidate(
          providerId: providerId,
          magnetUri: magnet,
          expectedInfoHash: item.infoHash,
        ),
      );
    }
    return downloadTorrentPayload(
      client: _client,
      downloadUri: item.torrentUri,
      providerId: providerId,
      expectedInfoHash: item.infoHash,
      allowInsecureHttp: site.allowInsecureHttp,
      requestTimeout: requestTimeout,
    );
  }

  void close() {
    if (_closesClient) _client.close();
  }
}

/// 多个 RSS 搜索站组成的视频资源 provider。
class RssSearchProvider implements VideoResourceProvider {
  RssSearchProvider({
    required Iterable<RssSearchSiteConfig> sites,
    http.Client? client,
    Duration requestTimeout = kDownloadDiscoveryTimeout,
    bool closesClient = true,
    this.priorityOffset = 0,
  }) : sites = List<RssSearchSiteConfig>.unmodifiable(sites),
       _client = RssSearchClient(
         client: client,
         requestTimeout: requestTimeout,
         closesClient: closesClient,
       );

  final List<RssSearchSiteConfig> sites;
  final RssSearchClient _client;
  final int priorityOffset;

  @override
  String get id => kRssResourceProviderId;

  @override
  int get priority {
    int? lowest;
    for (final RssSearchSiteConfig site in sites) {
      if (!site.appliesToVideo(null)) continue;
      if (lowest == null || site.priority < lowest) lowest = site.priority;
    }
    return priorityOffset + (lowest ?? 100);
  }

  /// 报「不限域」，由 [search] 按每个站自己勾的视频域逐站裁：一个 provider 对象
  /// 装着各勾各域的多个站，provider 级的域集合表达不了「A 站只动漫、B 站只电影」。
  /// 一个站都不适用时 [search] 返回零回执（没参与），不会打任何请求。
  @override
  Set<VideoDiscoveryCategory> get categories =>
      const <VideoDiscoveryCategory>{};

  /// 参与视频搜索的站（启用且勾了视频域），按优先级排序。
  List<RssSearchSiteConfig> get videoSites =>
      sites
          .where((RssSearchSiteConfig site) => site.appliesToVideo(null))
          .toList(growable: false)
        ..sort(
          (RssSearchSiteConfig a, RssSearchSiteConfig b) =>
              a.priority.compareTo(b.priority),
        );

  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async {
    final VideoDiscoveryCategory? category = request.media?.discoveryCategory;
    final String? onlySite = request.providerInstanceId;
    final List<RssSearchSiteConfig> applicable = videoSites
        .where(
          (RssSearchSiteConfig site) =>
              site.appliesToVideo(category) &&
              (onlySite == null || site.id == onlySite),
        )
        .toList(growable: false);
    if (applicable.isEmpty) return VideoResourceSearchResult();
    final List<String> queries = resourceSearchQueries(request);
    if (queries.isEmpty) {
      return ProviderBatchResult<VideoResourceCandidate>.failure(
        const ExternalProviderFailure(
          providerId: kRssResourceProviderId,
          operation: 'search',
          kind: ExternalProviderFailureKind.unsupported,
          message: 'a search query is required',
        ),
      );
    }
    final List<_SiteSearch> searches = await Future.wait(
      applicable.map(
        (RssSearchSiteConfig site) => _searchSite(site, queries, request),
      ),
    );
    final ProviderBatchResult<VideoResourceCandidate> merged =
        ProviderBatchResult.merge<VideoResourceCandidate>(
          searches.map((_SiteSearch search) => search.result),
        );
    return VideoResourceSearchResult(
      items: deduplicateVideoResources(merged.items).take(request.limit),
      failures: merged.failures,
      successfulProviderCount: merged.successfulProviderCount,
      sources: searches.map((_SiteSearch search) => search.report),
    );
  }

  Future<_SiteSearch> _searchSite(
    RssSearchSiteConfig site,
    List<String> queries,
    VideoResourceSearchRequest request,
  ) async {
    final String providerId = rssSiteProviderId(site.id);
    final List<VideoResourceCandidate> candidates = <VideoResourceCandidate>[];
    final List<ExternalProviderFailure> failures = <ExternalProviderFailure>[];
    final List<VideoResourceQueryReport> reports = <VideoResourceQueryReport>[];
    // 同一站逐词串行：多拼写并发打同一个公共站很容易被限流。
    for (final String query in queries) {
      try {
        final List<RssSearchItem> items = await _client.searchSite(
          site,
          query,
          page: request.page,
        );
        reports.add(
          VideoResourceQueryReport(query: query, itemCount: items.length),
        );
        candidates.addAll(
          items.map(
            (RssSearchItem item) => _RssResourceCandidate(
              site: site,
              item: item,
              providerPriority: priorityOffset + site.priority,
            ),
          ),
        );
      } on Object catch (error) {
        final ExternalProviderFailure failure =
            ExternalProviderFailure.fromException(
              providerId: providerId,
              operation: 'search',
              error: error,
            );
        failures.add(failure);
        reports.add(VideoResourceQueryReport(query: query, failure: failure));
      }
    }
    final bool succeeded = reports.any(
      (VideoResourceQueryReport r) => r.failure == null,
    );
    // 多个拼写各查一次，同一个种子只留一条。
    final List<VideoResourceCandidate> items = succeeded
        ? deduplicateVideoResources(candidates)
        : const <VideoResourceCandidate>[];
    return _SiteSearch(
      result: ProviderBatchResult<VideoResourceCandidate>(
        items: items,
        failures: succeeded
            ? failures
            : <ExternalProviderFailure>[failures.first],
        successfulProviderCount: succeeded ? 1 : 0,
      ),
      report: VideoResourceSourceReport(
        providerId: providerId,
        queries: reports,
        itemCount: items.length,
        failures: failures,
        succeeded: succeeded,
      ),
    );
  }

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) async {
    if (candidate is! _RssResourceCandidate) {
      throw const ExternalProviderFailure(
        providerId: kRssResourceProviderId,
        operation: 'resolve',
        kind: ExternalProviderFailureKind.unsupported,
        message: 'candidate belongs to another provider',
      );
    }
    return _client.resolveItem(candidate.site, candidate.item);
  }

  @override
  void close() => _client.close();
}

class _SiteSearch {
  const _SiteSearch({required this.result, required this.report});

  final ProviderBatchResult<VideoResourceCandidate> result;
  final VideoResourceSourceReport report;
}

class _RssResourceCandidate extends VideoResourceCandidate {
  _RssResourceCandidate({
    required this.site,
    required this.item,
    required int providerPriority,
  }) : super(
         providerId: kRssResourceProviderId,
         providerInstanceId: site.id,
         remoteId: item.remoteId,
         title: item.title,
         providerPriority: providerPriority,
         infoHash: item.infoHash,
         sizeBytes: item.sizeBytes,
         seeders: item.seeders,
         leechers: item.leechers,
         completed: item.downloads,
         publishedAt: item.publishedAt,
         category: item.category,
         resolution: _descriptor(item).resolution,
         releaseGroup: _descriptor(item).releaseGroup,
         trusted: item.trusted,
         detailsUrl: item.detailsUrl,
         magnetUri: persistableCandidateMagnet(item.magnetUri, item.infoHash),
       );

  final RssSearchSiteConfig site;
  final RssSearchItem item;

  static AnimeReleaseDescriptor _descriptor(RssSearchItem item) =>
      parseAnimeReleaseDescriptor(item.title);
}
