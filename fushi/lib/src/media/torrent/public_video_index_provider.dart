import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/torrent/public_video_index_client.dart';
import 'package:fushi/src/media/torrent/search_query_script.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';

/// 内置公共索引器的 provider id（设置页开关、停用清单偏好、去重键三处共用）。
const String kApibayResourceProviderId = 'apibay';
const String kKnabenResourceProviderId = 'knaben';

/// apibay 分类：201 Movies / 207 HD Movies / 205 TV shows / 208 HD TV shows。
const List<int> kApibayMovieCategories = <int>[207, 201];
const List<int> kApibayTvCategories = <int>[208, 205];

/// Knaben 分类层级根：3000000 Movies / 2000000 TV。
const int kKnabenMovieCategory = 3000000;
const int kKnabenTvCategory = 2000000;

String _normalizedPublicIndexTitle(String value) => foldFullWidthAscii(value)
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ')
    .toLowerCase();

/// 判据走共享的书写系统分类器，**不再枚举 CJK 区段**。
///
/// 旧判据是「有 ASCII 字母数字 **且** 不含 CJK」，两头都错：
/// * 含一个汉字就整条拦 → `Fate/stay night 劇場版` 这类混排被误杀，而 apibay 对
///   它并不退化（有拉丁词可匹配）；实测证据只覆盖纯 CJK 查询，实现范围却大于
///   证据范围。
/// * `[A-Za-z0-9]` 把西里尔 / 希腊 / 泰文 / 阿拉伯文也一并判成「不可搜」，是
///   「非拉丁 = 不可搜」的反向假设；同时半角片假名、Hangul 兼容字母都漏在区段
///   外，照旧会触发原 bug。
///
/// 另外注意报告里那条真实用例 `薬屋のひとりごと 第2期` 含一个 ASCII `2`——按
/// 「有 ASCII 字母数字」判它反而是「可搜」的，旧判据全靠 CJK 排除才拦住。

bool _isPublicIndexSearchable(String value) => isLatinScriptExpressible(value);

/// 把资源请求转换成公共综合索引器真正能表达的查询。
///
/// apibay 对 CJK 查询不会返回空集，而会把它当近似空查询返回当前热门榜；这比显式
/// 失败更危险，因为 UI 会把完全不相关的条目伪装成正常搜索结果。当前查询若命中
/// 媒体的展示标题、原名或别名，可以用同一元数据里的拉丁别名；日文和中文不会因为
/// 都属于 CJK 就被判等。用户另行手输的 CJK 查询不能擅自退回原媒体别名（那会搜索
/// 另一个作品），只能让该 provider 判 unsupported。
String? publicVideoIndexSearchQuery(VideoResourceSearchRequest request) {
  final String requested = request.effectiveQuery.trim();
  if (requested.isEmpty) return null;
  if (_isPublicIndexSearchable(requested)) return requested;

  final VideoMediaReference? media = request.media;
  if (media == null) return null;
  final String normalizedRequested = _normalizedPublicIndexTitle(requested);
  final List<String> knownTitles = <String>[
    media.title,
    if (media.originalTitle != null) media.originalTitle!,
    ...media.aliases,
  ];
  final bool isKnownTitle = knownTitles.any(
    (String title) => _normalizedPublicIndexTitle(title) == normalizedRequested,
  );
  if (!isKnownTitle) return null;
  for (final String candidate in <String>[
    ...media.aliases,
    if (media.originalTitle != null) media.originalTitle!,
    media.title,
  ]) {
    final String value = candidate.trim();
    if (_isPublicIndexSearchable(value)) return value;
  }
  return null;
}

/// 两家公共索引器共用的候选行。
///
/// 一个 candidate 类而不是两个：它们的 `resolve` 都只是「把磁链交出去」，
/// 差异全在抓取那一段，没有任何理由在这一层再分叉。
class PublicVideoIndexCandidate extends VideoResourceCandidate {
  PublicVideoIndexCandidate({
    required this.torrent,
    required String providerId,
    required String providerInstanceId,
    required int providerPriority,
  }) : super(
         providerId: providerId,
         providerInstanceId: providerInstanceId,
         remoteId: torrent.infoHash,
         title: torrent.title,
         providerPriority: providerPriority,
         infoHash: torrent.infoHash,
         sizeBytes: torrent.sizeBytes,
         seeders: torrent.seeders,
         leechers: torrent.leechers,
         completed: torrent.completed,
         publishedAt: torrent.publishedAt,
         category: torrent.category,
         resolution: torrent.resolution,
         releaseGroup: torrent.releaseGroup,
         detailsUrl: torrent.detailsUrl,
         magnetUri: torrent.magnet,
       );

  final PublicVideoIndexTorrent torrent;
}

/// apibay（The Pirate Bay）内置资源索引器：电影 + 剧集，零配置。
///
/// 域：`movie` / `tv`。**刻意不含 `anime`**——动漫由 Nyaa 负责，那里的字幕组
/// 标题/分类远比综合站精确，让综合站也进动漫域只会把 Nyaa 的结果挤下去。
class ApibayVideoResourceProvider implements VideoResourceProvider {
  ApibayVideoResourceProvider({
    required ApibayClient client,
    this.priority = 200,
    bool closesClient = false,
  }) : _client = client,
       _closesClient = closesClient;

  final ApibayClient _client;
  final bool _closesClient;

  @override
  final int priority;

  @override
  String get id => kApibayResourceProviderId;

  @override
  Set<VideoDiscoveryCategory> get categories => const <VideoDiscoveryCategory>{
    VideoDiscoveryCategory.movie,
    VideoDiscoveryCategory.tv,
  };

  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async {
    final String? query = publicVideoIndexSearchQuery(request);
    if (query == null) {
      // 「这条查询我表达不了」是**未参与**，不是失败。
      //
      // 表达成 failure 有两个真实后果：
      // ① 订阅 / 下载流水线把 provider failure 直接 `throw`
      //    （video_download_subscription_service.dart 的 _failureBelongsToProvider /
      //    isTotalFailure 两条路径）。而这两条路径重建 VideoMediaReference 时
      //    结构上拿不到 aliases（订阅行与 job 都不持久化别名），于是 CJK 标题的
      //    订阅每一轮定时任务必然抛、永不自愈——「单来源配额 = 自杀开关」的形状。
      // ② UI 侧 ExternalProviderFailureKind 全仓没有一处按值分支，failure.message
      //    也从不进任何 Text，所以 unsupported 与超时/限流完全等价：用户看到的是
      //    「加载失败 + 重试」，而重试永远不可能成功，唯一可行动作（换罗马字标题）
      //    拿不到。
      //
      // 返回零条 + successfulProviderCount 0 让它落进既有的 hasNoActiveProvider
      // 第三态：聚合层照常合并其它 provider，只有这家没参与。
      return ProviderBatchResult<VideoResourceCandidate>(
        items: const <VideoResourceCandidate>[],
      );
    }
    try {
      final List<PublicVideoIndexTorrent> torrents = await _client.search(
        query,
        categories:
            request.media?.discoveryCategory == VideoDiscoveryCategory.tv
            ? kApibayTvCategories
            : kApibayMovieCategories,
      );
      return ProviderBatchResult<VideoResourceCandidate>(
        items: deduplicateVideoResources(
          torrents.map(
            (PublicVideoIndexTorrent torrent) => PublicVideoIndexCandidate(
              torrent: torrent,
              providerId: id,
              providerInstanceId: 'apibay.org',
              providerPriority: priority,
            ),
          ),
        ).take(request.limit).toList(),
        successfulProviderCount: 1,
      );
    } on Object catch (error) {
      return ProviderBatchResult<VideoResourceCandidate>.failure(
        ExternalProviderFailure.fromException(
          providerId: id,
          operation: 'search',
          error: error,
        ),
      );
    }
  }

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) async =>
      resolvePublicVideoIndexCandidate(candidate, id);

  @override
  void close() {
    if (_closesClient) _client.close();
  }
}

/// Knaben 内置资源索引器：电影 + 剧集，零配置。域约定同 apibay。
class KnabenVideoResourceProvider implements VideoResourceProvider {
  KnabenVideoResourceProvider({
    required KnabenClient client,
    this.priority = 210,
    bool closesClient = false,
  }) : _client = client,
       _closesClient = closesClient;

  final KnabenClient _client;
  final bool _closesClient;

  @override
  final int priority;

  @override
  String get id => kKnabenResourceProviderId;

  @override
  Set<VideoDiscoveryCategory> get categories => const <VideoDiscoveryCategory>{
    VideoDiscoveryCategory.movie,
    VideoDiscoveryCategory.tv,
  };

  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async {
    // Knaben **不走**公共索引器的拉丁词门。它的 `search_type: '100%'` 是硬标题
    // 过滤（见 public_video_index_client.dart 里那条注释：`score` 会把 query 当
    // 权重提示返回无关热门，`100%` 才是「标题必须含关键词」），对 CJK 查询返回的
    // 是**正确的 0 条**，不是热门榜。把它一起拦掉是纯功能删除——恰恰删掉了
    // Knaben 相对 apibay 的价值（它聚合的站里有带原文标题的发布）。
    // 按能力分流，不按「两家都在这个文件里」分流。
    final String query = request.effectiveQuery.trim();
    if (query.isEmpty) {
      return ProviderBatchResult<VideoResourceCandidate>(
        items: const <VideoResourceCandidate>[],
      );
    }
    try {
      final List<PublicVideoIndexTorrent> torrents = await _client.search(
        query,
        categories: <int>[
          request.media?.discoveryCategory == VideoDiscoveryCategory.tv
              ? kKnabenTvCategory
              : kKnabenMovieCategory,
        ],
        limit: request.limit,
      );
      return ProviderBatchResult<VideoResourceCandidate>(
        items: deduplicateVideoResources(
          torrents.map(
            (PublicVideoIndexTorrent torrent) => PublicVideoIndexCandidate(
              torrent: torrent,
              providerId: id,
              providerInstanceId: 'knaben.org',
              providerPriority: priority,
            ),
          ),
        ).take(request.limit).toList(),
        successfulProviderCount: 1,
      );
    } on Object catch (error) {
      return ProviderBatchResult<VideoResourceCandidate>.failure(
        ExternalProviderFailure.fromException(
          providerId: id,
          operation: 'search',
          error: error,
        ),
      );
    }
  }

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) async =>
      resolvePublicVideoIndexCandidate(candidate, id);

  @override
  void close() {
    if (_closesClient) _client.close();
  }
}

/// 候选 → 磁链 payload。两家 provider 共用：`resolve` 的全部内容就是「这条候选
/// 确实是我发出去的」+「把磁链交出去」，没有第二种写法。
TorrentAddPayload resolvePublicVideoIndexCandidate(
  VideoResourceCandidate candidate,
  String providerId,
) {
  if (candidate is! PublicVideoIndexCandidate ||
      candidate.providerId != providerId) {
    throw ExternalProviderFailure(
      providerId: providerId,
      operation: 'resolve',
      kind: ExternalProviderFailureKind.unsupported,
      message: 'candidate belongs to another provider',
    );
  }
  return TorrentMagnetPayload(
    magnetUri: candidate.torrent.magnet,
    torrentId: candidate.torrent.infoHash,
  );
}
