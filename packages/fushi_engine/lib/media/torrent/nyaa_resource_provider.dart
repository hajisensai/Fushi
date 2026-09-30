import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/nyaa_client.dart';
import 'package:fushi_engine/media/torrent/search_query_script.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';

/// Nyaa 内置索引器的 provider id（停用清单偏好、设置页开关行、去重键共用）。
const String kNyaaResourceProviderId = 'nyaa';

class NyaaVideoResourceProvider implements VideoResourceProvider {
  NyaaVideoResourceProvider({
    required NyaaClient client,
    this.category = '1_0',
    this.filter = '0',
    this.priority = 100,
    bool closesClient = false,
  })  : _client = client,
        _closesClient = closesClient;

  final NyaaClient _client;
  final bool _closesClient;
  final String category;
  final String filter;

  @override
  final int priority;

  @override
  String get id => kNyaaResourceProviderId;

  /// 只进动漫域。nyaa.si 的 `1_0` 分类本身就是 Anime，拿它去搜电影/剧集只会
  /// 返回噪声——所以这不是策略，是这家索引器的内容边界。
  @override
  Set<VideoDiscoveryCategory> get categories => const <VideoDiscoveryCategory>{
        VideoDiscoveryCategory.anime,
      };

  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async {
    final List<String> queries = nyaaSearchQueries(request);
    if (queries.isEmpty) {
      return ProviderBatchResult<VideoResourceCandidate>.failure(
        const ExternalProviderFailure(
          providerId: 'nyaa',
          operation: 'search',
          kind: ExternalProviderFailureKind.unsupported,
          message: 'a search query is required',
        ),
      );
    }
    final List<VideoResourceCandidate> candidates = <VideoResourceCandidate>[];
    final List<ExternalProviderFailure> failures = <ExternalProviderFailure>[];
    final List<VideoResourceQueryReport> reports =
        <VideoResourceQueryReport>[];
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
            (NyaaTorrent torrent) => _NyaaResourceCandidate(torrent, priority),
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
    final bool succeeded =
        reports.any((VideoResourceQueryReport r) => r.failure == null);
    // 多个拼写各查一次，同一个种子（infohash）只留一条。
    final List<VideoResourceCandidate> items = succeeded
        ? deduplicateVideoResources(candidates).take(request.limit).toList()
        : const <VideoResourceCandidate>[];
    return VideoResourceSearchResult(
      items: items,
      failures:
          succeeded ? failures : <ExternalProviderFailure>[failures.first],
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
      throw const ExternalProviderFailure(
        providerId: 'nyaa',
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
    ...romanized.take(1),
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
List<String> nyaaSearchQueries(VideoResourceSearchRequest request) {
  final String explicit = request.query?.trim() ?? '';
  final VideoMediaReference? media = request.media;
  if (explicit.isEmpty) return preferredNyaaSearchQueries(request);
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
    for (final String candidate in preferredNyaaSearchQueries(
      VideoResourceSearchRequest(media: media),
    ))
      if (seen.add(_nyaaTitleKey(candidate))) candidate,
  ];
}

String _nyaaTitleKey(String value) => foldFullWidthAscii(value)
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ')
    .toLowerCase();

class _NyaaResourceCandidate extends VideoResourceCandidate {
  _NyaaResourceCandidate(this.torrent, int providerPriority)
      : super(
          providerId: 'nyaa',
          providerInstanceId: 'nyaa.si',
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
