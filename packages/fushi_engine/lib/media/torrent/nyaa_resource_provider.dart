import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/nyaa_client.dart';
import 'package:fushi_engine/media/torrent/search_query_script.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';

/// Nyaa 式站点的格式名 = provider id 前缀（`nyaa:<siteId>`）。旧内置源的持久化
/// id（`nyaa` / `nyaa:nyaa.si`）也是这个前缀——存量订阅据此解析到用户的 Nyaa 式
/// 站点（`VideoResourceRegistry.resolveProvider`）。
const String kNyaaResourceProviderId = 'nyaa';

/// 一个用户 Nyaa 式 BT 站的资源 provider。
class NyaaVideoResourceProvider implements LabeledVideoResourceProvider {
  NyaaVideoResourceProvider({
    required NyaaClient client,
    required this.siteId,
    required Map<VideoDiscoveryCategory, String> categoryByDomain,
    String? displayName,
    this.filter = '0',
    this.priority = 100,
    bool closesClient = false,
  }) : _client = client,
       _closesClient = closesClient,
       categoryByDomain = Map<VideoDiscoveryCategory, String>.unmodifiable(
         categoryByDomain,
       ),
       displayName = displayName ?? Uri.parse(client.baseUrl).host;

  final NyaaClient _client;
  final bool _closesClient;

  /// 站点 id（`BtSiteConfig.id`），也是候选的 providerInstanceId。
  final String siteId;

  /// 视频域 → 该站分类号（探测时从站点分类下拉映射出来的）。
  final Map<VideoDiscoveryCategory, String> categoryByDomain;
  final String filter;

  @override
  final String displayName;

  @override
  final int priority;

  @override
  String get id => '$kNyaaResourceProviderId:$siteId';

  /// 只进站点确有分类的视频域（用户勾选 ∩ 站点分类，组装点已求好交集）。
  /// 拿动画分类去搜电影只会返回噪声，所以这是站点的内容边界，不是策略。
  @override
  Set<VideoDiscoveryCategory> get categories => categoryByDomain.keys.toSet();

  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async {
    final List<String> queries = nyaaSearchQueries(request);
    final VideoDiscoveryCategory? domain = request.media?.discoveryCategory;
    final String? category = domain == null
        ? (categoryByDomain.length == 1 ? categoryByDomain.values.first : null)
        : categoryByDomain[domain];
    if (category == null) {
      // 这个域在本站没有分类：未参与，不是失败（同 apibay 遇纯 CJK 词）。
      return ProviderBatchResult<VideoResourceCandidate>(
        items: const <VideoResourceCandidate>[],
      );
    }
    if (queries.isEmpty) {
      return ProviderBatchResult<VideoResourceCandidate>.failure(
        ExternalProviderFailure(
          providerId: id,
          operation: 'search',
          kind: ExternalProviderFailureKind.unsupported,
          message: 'a search query is required',
        ),
      );
    }
    final List<VideoResourceCandidate> candidates = <VideoResourceCandidate>[];
    final List<ExternalProviderFailure> failures = <ExternalProviderFailure>[];
    final List<VideoResourceQueryReport> reports = <VideoResourceQueryReport>[];
    for (final String query in queries) {
      try {
        final List<NyaaTorrent> torrents = await _client.search(
          query,
          category: category,
          filter: filter,
          page: request.page,
        );
        reports.add(
          VideoResourceQueryReport(query: query, itemCount: torrents.length),
        );
        candidates.addAll(
          torrents.map(
            (NyaaTorrent torrent) =>
                _NyaaResourceCandidate(torrent, siteId, priority),
          ),
        );
      } on Object catch (error) {
        final ExternalProviderFailure failure =
            ExternalProviderFailure.fromException(
              providerId: id,
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
    // 多个拼写各查一次，同一个种子（infohash）只留一条。
    final List<VideoResourceCandidate> items = succeeded
        ? deduplicateVideoResources(candidates).take(request.limit).toList()
        : const <VideoResourceCandidate>[];
    return VideoResourceSearchResult(
      items: items,
      failures: succeeded
          ? failures
          : <ExternalProviderFailure>[failures.first],
      successfulProviderCount: succeeded ? 1 : 0,
      sources: <VideoResourceSourceReport>[
        VideoResourceSourceReport(
          providerId: id,
          queries: reports,
          itemCount: items.length,
          failures: failures,
          succeeded: succeeded,
        ),
      ],
    );
  }

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) async {
    if (candidate is! _NyaaResourceCandidate) {
      throw ExternalProviderFailure(
        providerId: id,
        operation: 'resolve',
        kind: ExternalProviderFailureKind.unsupported,
        message: 'candidate belongs to another provider',
      );
    }
    return TorrentMagnetPayload(
      magnetUri: candidate.torrent.magnet,
      torrentId: candidate.torrent.infoHash.toLowerCase(),
    );
  }

  @override
  void close() {
    if (_closesClient) _client.close();
  }
}

/// 作品在 Nyaa 上的**默认**检索词：罗马字（拉丁拼写）与日文原名各取一个，都
/// 没有才退回展示标题。显式查询词原样返回（搜索框预填、订阅默认词只要一条）。
///
/// Nyaa 真正发出的查询集合见 [nyaaSearchQueries]——这里只是「首选词」。
List<String> preferredNyaaSearchQueries(VideoResourceSearchRequest request) {
  final String explicitQuery = request.query?.trim() ?? '';
  if (explicitQuery.isNotEmpty) return <String>[explicitQuery];
  return _nyaaWorkQueries(request, maxRomanized: 1);
}

/// 同一作品最多查几种拉丁拼写（BUG-2818）。
///
/// 元数据排在最前的「罗马字」不一定是发布组用的写法：TMDB 的 JP 区别名可能是
/// 官方风格化写法 `FX Senshi KURUMICHAN`，发布名却一律是 `FX Senshi Kurumi-chan`
/// ——Nyaa 把 `KURUMICHAN` 当成另一个词，0 条。只查第一个拉丁拼写 = 押宝在元数据
/// 的排序上；罗马字 / 英文名 / 主标题各查一次才不依赖它。上限是请求预算：Nyaa
/// 逐词串行请求，每多一种拼写多一次往返。
const int kNyaaMaxRomanizedQueries = 3;

/// 作品标题候选（别名 → 原名 → 标题 → 有效查询词，大小写不敏感去重）按书写系统
/// 分组：拉丁拼写取前 [maxRomanized] 个、日文取一个，都没有才退回其它标题一个。
List<String> _nyaaWorkQueries(
  VideoResourceSearchRequest request, {
  required int maxRomanized,
}) {
  final VideoMediaReference? media = request.media;
  final List<String> candidates = <String>[
    if (media != null) ...media.aliases,
    if (media?.originalTitle case final String original) original,
    if (media != null) media.title,
    request.effectiveQuery,
  ];
  final List<String> romanized = <String>[];
  final List<String> japanese = <String>[];
  final List<String> fallback = <String>[];
  final Set<String> seen = <String>{};
  for (final String candidate in candidates) {
    final String value = candidate.trim();
    final String key = value.toLowerCase();
    if (value.isEmpty || !seen.add(key)) continue;
    if (RegExp(r'[A-Za-z]').hasMatch(value) &&
        !RegExp(r'[\u3040-\u30ff\u3400-\u9fff]').hasMatch(value)) {
      romanized.add(value);
    } else if (RegExp(r'[\u3040-\u30ff]').hasMatch(value) ||
        value == media?.originalTitle?.trim()) {
      japanese.add(value);
    } else {
      fallback.add(value);
    }
  }
  return <String>[
    ...romanized.take(maxRomanized),
    ...japanese.take(1),
    if (romanized.isEmpty && japanese.isEmpty) ...fallback.take(1),
  ];
}

/// Nyaa 实际要发的查询词（BUG-2794）：显式词在前，作品的拼写候选作补充。
///
/// 旧契约是「有显式词就只搜显式词」。可资源页会把首选词**预填**进搜索框，于是
/// 预填词一律变成显式词：TMDB 卡片没有罗马字别名时预填的是日文原名
/// `葬送のフリーレン`，Nyaa 回 0 条（同一作品 `Frieren` 有 75 条），而作品自己的
/// 罗马字 / 日文拼写再也没机会被查——别名被显式词覆盖了。
///
/// 现在显式词只是候选之一。补查作品拼写的条件：
/// * 显式词本身就是这部作品的某个已知标题（标题 / 原名 / 别名，含预填词）——
///   同一作品的另一种拼写，补查不会搜到别的作品；
/// * 或显式词里没有拉丁词（Nyaa 发布名绝大多数是罗马字 / 英文，纯 CJK 词命中率
///   极低）。
/// 用户手输的拉丁词（`Frieren S2 1080p`）是在收窄，不补查，免得把收窄冲掉。
/// 没有作品身份（纯关键词搜索）时只有显式词可查。
///
/// 作品拼写查全部不同的拉丁拼写（至多 [kNyaaMaxRomanizedQueries] 个）加日文原名，
/// 不像 [preferredNyaaSearchQueries] 那样只各取一个（BUG-2818）。
List<String> nyaaSearchQueries(VideoResourceSearchRequest request) {
  final String explicit = request.query?.trim() ?? '';
  final VideoMediaReference? media = request.media;
  if (explicit.isEmpty) {
    return _nyaaWorkQueries(request, maxRomanized: kNyaaMaxRomanizedQueries);
  }
  if (media == null) return <String>[explicit];
  final String normalized = _nyaaTitleKey(explicit);
  final bool knownTitle = <String?>[
    media.title,
    media.originalTitle,
    ...media.aliases,
  ].any((String? title) => title != null && _nyaaTitleKey(title) == normalized);
  if (!knownTitle && isLatinScriptExpressible(explicit)) {
    return <String>[explicit];
  }
  final Set<String> seen = <String>{normalized};
  return <String>[
    explicit,
    for (final String candidate in _nyaaWorkQueries(
      VideoResourceSearchRequest(media: media),
      maxRomanized: kNyaaMaxRomanizedQueries,
    ))
      if (seen.add(_nyaaTitleKey(candidate))) candidate,
  ];
}

String _nyaaTitleKey(String value) => foldFullWidthAscii(
  value,
).trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

class _NyaaResourceCandidate extends VideoResourceCandidate {
  _NyaaResourceCandidate(this.torrent, String siteId, int providerPriority)
    : super(
        providerId: kNyaaResourceProviderId,
        providerInstanceId: siteId,
        remoteId: torrent.infoHash.toLowerCase(),
        title: torrent.title,
        providerPriority: providerPriority,
        infoHash: torrent.infoHash.toLowerCase(),
        sizeBytes: torrent.sizeBytes,
        seeders: torrent.seeders,
        leechers: torrent.leechers,
        completed: torrent.downloads,
        publishedAt: torrent.pubDate,
        category: torrent.categoryId,
        resolution: torrent.resolution,
        releaseGroup: torrent.releaseGroup,
        trusted: torrent.trusted,
        detailsUrl: torrent.pageUrl,
        magnetUri: torrent.magnet,
      );

  final NyaaTorrent torrent;
}
