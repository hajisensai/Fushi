library;

import 'dart:async';

import 'package:fushi_engine/media/video/discovery/video_franchise.dart';
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_adapters.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/anilist_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/discovery/anime_tmdb_cross_reference.dart';
import 'package:fushi_engine/media/video/metadata/anime_identity_mapping.dart';
import 'package:fushi_engine/media/video/metadata/mal_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_airing_status.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_merge.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/media/video/scraper/title_normalizer.dart';
import 'package:fushi_engine/media/video/discovery/video_metadata_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi_engine/foundation/engine_log.dart';

/// 发现页的生产聚合服务。
///
/// 每个来源独立返回成功或脱敏失败；聚合层只在所有可用来源均失败时产生全失败，
/// 单来源故障不会清空其他来源的数据。
class VideoDiscoveryService {
  VideoDiscoveryService({
    required Iterable<VideoDiscoveryProvider> providers,
    Iterable<VideoMetadataProvider> metadataProviders =
        const <VideoMetadataProvider>[],
    bool closesProviders = false,
    Set<String>? searchProviderIds,
    String? metadataLocale,
    AnimeTmdbCrossReference? crossReference,
  })  : _metadataLocale = metadataLocale,
        _crossReference = crossReference,
        _providers = List<VideoDiscoveryProvider>.unmodifiable(
          providers.toList()
            ..sort(
              (VideoDiscoveryProvider a, VideoDiscoveryProvider b) =>
                  a.priority.compareTo(b.priority),
            ),
        ),
        _metadataProviders = <VideoMetadataProviderKind, VideoMetadataProvider>{
          for (final VideoMetadataProvider provider in metadataProviders)
            provider.providerKind: provider,
        },
        _closesProviders = closesProviders,
        _searchProviderIds = searchProviderIds == null
            ? null
            : Set<String>.unmodifiable(searchProviderIds);

  /// [discoveryAvailable] 是宿主的商店合规门（app 传
  /// `StoreRestrictedCapability.externalDiscovery.isAvailable`，无头服务端恒 true）：
  /// 必填，任何装配点都得显式声明，漏传编译不过。
  factory VideoDiscoveryService.production(
    VideoSourceScrapeGlobalConfig config, {
    required bool discoveryAvailable,
  }) {
    final VideoMetadataProviderRegistry catalog =
        VideoMetadataProviderRegistry.production(config);
    final AniListVideoMetadataProvider anilist = AniListVideoMetadataProvider();
    // iOS 上不登记任何**发现** provider（app 的 `StoreRestrictedCapability.externalDiscovery`）；
    // metadata provider 照常保留——那条链路服务的是本地媒体库的刮削（MAL / TMDB /
    // AniDB 补全已入库文件的作品资料），与「浏览站上有什么可看」不是一回事，
    // 两者共用本类只是因为它们查的是同一批 API。
    // 发现页的搜索源只收「能当目录浏览」的资料源：AniDB（2026-09-20 起装进生产
    // registry 作默认刮削主源）的 `search` 是本地标题目录，没有封面 / 简介 / 评分，
    // 摆进发现页只是一列裸标题；它在这里的用途仅限 [metadataProviders]——发现结果
    // 的 AniDB 身份解析（`discovery_anidb_identity.dart`）。发现与刮削是不同域。
    final List<VideoMetadataProvider> searchable = <VideoMetadataProvider>[
      for (final VideoMetadataProvider provider in catalog.providers)
        if (isDiscoverySearchKind(provider.providerKind)) provider,
    ];
    return VideoDiscoveryService(
      providers: <VideoDiscoveryProvider>[
        if (discoveryAvailable)
          for (final VideoMetadataProvider provider in searchable)
            if (provider.providerKind == VideoMetadataProviderKind.tmdb)
              // Preserve TMDB's discovery paging and filter capabilities.
              TmdbVideoDiscoveryProvider(
                apiKey: config.tmdbApiKey,
                language: config.locale,
              )
            else
              VideoMetadataSearchDiscoveryProvider(
                provider: provider,
                categories: const <VideoDiscoveryCategory>{
                  VideoDiscoveryCategory.anime,
                },
                priority: 5,
              ),
        if (discoveryAvailable) AniListVideoDiscoveryProvider(),
      ],
      metadataProviders: <VideoMetadataProvider>[
        ...catalog.providers,
        anilist,
      ],
      // AniList 也是搜索源：它只属于发现域（不进刮削 registry），但单靠 MAL 撑
      // 番剧搜索时，Jikan 一挂（它常年间歇性 504）且 TMDB 没配 key，搜索就一条
      // 都出不来；AniList 的 `SEARCH_MATCH` 还认中文/日文别名，结果带 MAL id，
      // 与 MAL 结果按强 ID 合并、不会重复。
      searchProviderIds: <String>{
        for (final VideoMetadataProvider provider in searchable)
          provider.providerKind.name,
        kAniListDiscoveryProviderId,
      },
      closesProviders: true,
      // 详情合并按资料语言选文本（与刮削协调器 `supplementVideoMetadata(...,
      // preferredLanguage: _locale)` 同一判据）；TMDB provider 也是按这个 locale
      // 请求的，所以「TMDB 文本 = 资料语言」这条约定成立。
      metadataLocale: config.locale,
      // 动画发现条目（AniList / MAL）的简介恒英文；详情按 MAL id 经 Fribb 交叉
      // 引用找到 TMDB id，才能拿到资料语言的简介（见 [_tmdbLookupFromIdentityMap]）。
      // 落盘的紧凑索引，查询只读本地、下载在后台（见 anime_tmdb_cross_reference）。
      crossReference: AnimeTmdbCrossReferenceStore(),
    );
  }

  /// 生产 registry 里哪些刮削 provider 可作发现页搜索源：AniDB 不算（见
  /// [VideoDiscoveryService.production]）。守卫
  /// `video_discovery_aggregated_sources_guard_test` 钉住。
  static bool isDiscoverySearchKind(VideoMetadataProviderKind kind) =>
      kind != VideoMetadataProviderKind.anidb;

  final List<VideoDiscoveryProvider> _providers;
  final Map<VideoMetadataProviderKind, VideoMetadataProvider>
      _metadataProviders;
  final bool _closesProviders;
  final Set<String>? _searchProviderIds;

  /// Fribb 交叉索引：动画条目缺 TMDB id 时按 MAL id 补一个（只认唯一明确
  /// 映射）。`null` = 不补（测试 / 无此能力的装配）。
  final AnimeTmdbCrossReference? _crossReference;

  /// 本地交叉索引被后台刷新替换后发事件：详情 / Hero 据此重取一次，把英文
  /// 简介换成资料语言的。没有交叉索引时是空流。
  Stream<void> get detailsUpdates =>
      _crossReference?.updates ?? const Stream<void>.empty();

  /// 资料语言（BCP-47）。详情合并时决定简介 / 标语 / 类型取哪个来源；`null`
  /// 时退化成「主源优先、空才补」。
  final String? _metadataLocale;
  bool _closed = false;

  /// 聚合来源清单（按 priority 排序后的 provider id）。
  ///
  /// BUG-1538 守卫用：发现页无论下载代理是 direct 还是 proxy 模式都走同一份
  /// 聚合来源——[VideoDiscoveryService.production] 的签名里根本没有代理输入，
  /// 来源选择结构上不可能随代理开关分叉；本 getter 把这份组成暴露给测试钉死。
  @visibleForTesting
  List<String> get providerIdsForTesting => _providers
      .map((VideoDiscoveryProvider provider) => provider.id)
      .toList(growable: false);

  /// provider id -> 用户可见来源名。找不到时退回 id（服务自身产生的 failure，例如
  /// `discovery` 这个合成 id，本来就没有对应的来源）。
  String displayNameFor(String providerId) {
    for (final VideoDiscoveryProvider provider in _providers) {
      if (provider.id == providerId) return provider.displayName;
    }
    return providerId;
  }

  @visibleForTesting
  Set<String> get searchProviderIdsForTesting => <String>{
        for (final VideoDiscoveryProvider provider in _providers)
          if (_supportsRequest(
            provider,
            const VideoDiscoveryRequest(query: 'catalog'),
          ))
            provider.id,
      };

  /// 聚合所有支持该请求的来源。[onProgress]：每有一个来源返回（且还有来源没
  /// 返回）就以「已返回来源」的合并结果回调一次，页面据此先显示快的来源，不必等
  /// 最慢的那个；返回值恒是全部来源到齐后的最终结果。
  Future<ProviderBatchResult<VideoDiscoveryPage>> load(
    VideoDiscoveryRequest request, {
    void Function(ProviderBatchResult<VideoDiscoveryPage> partial)? onProgress,
  }) async {
    if (_closed) {
      return ProviderBatchResult<VideoDiscoveryPage>.failure(
        const ExternalProviderFailure(
          providerId: 'discovery',
          operation: 'load',
          kind: ExternalProviderFailureKind.unavailable,
          message: 'discovery service is closed',
        ),
      );
    }
    final List<VideoDiscoveryProvider> selected = _providers
        .where(
          (VideoDiscoveryProvider provider) =>
              _supportsRequest(provider, request),
        )
        .toList(growable: false);
    if (selected.isEmpty) {
      return ProviderBatchResult<VideoDiscoveryPage>.success(
        <VideoDiscoveryPage>[
          VideoDiscoveryPage(
            items: const <VideoDiscoveryItem>[],
            page: request.page,
            hasMore: false,
          ),
        ],
        successfulProviderCount: 0,
      );
    }

    // 按 selected 的顺序占位：合并结果只取决于「哪些来源已返回」，与返回先后
    // 无关（round-robin 的轮次顺序固定），渐进结果与最终结果同一口径。
    final List<_ProviderResponse?> slots = List<_ProviderResponse?>.filled(
      selected.length,
      null,
    );
    int pending = selected.length;
    await Future.wait(<Future<void>>[
      for (int i = 0; i < selected.length; i++)
        _invokeWindow(selected[i], request).then((_ProviderResponse response) {
          slots[i] = response;
          pending -= 1;
          if (pending > 0 && onProgress != null && !_closed) {
            onProgress(
              _aggregate(<_ProviderResponse>[
                for (final _ProviderResponse? slot in slots)
                  if (slot != null) slot,
              ], request),
            );
          }
        }),
    ]);
    return _aggregate(<_ProviderResponse>[
      for (final _ProviderResponse? slot in slots) slot!,
    ], request);
  }

  /// 把已返回来源的响应合并成一页。
  ProviderBatchResult<VideoDiscoveryPage> _aggregate(
    List<_ProviderResponse> responses,
    VideoDiscoveryRequest request,
  ) {
    final List<ExternalProviderFailure> failures = <ExternalProviderFailure>[];
    int successfulProviders = 0;
    bool hasMore = false;
    for (final _ProviderResponse response in responses) {
      failures.addAll(response.result.failures);
      successfulProviders += response.result.successfulProviderCount;
      hasMore = hasMore || response.hasMore;
    }

    final List<VideoDiscoveryItem> interleaved =
        _roundRobin(<List<VideoDiscoveryItem>>[
      for (final _ProviderResponse response in responses)
        _prepareProviderItems(response, request),
    ]);
    final List<VideoDiscoveryItem> mergedWindow = mergeVideoDiscoveryItems(
      interleaved,
      request: request,
      preferredLanguage: _metadataLocale,
    );
    final int pageOffset = (request.page - 1) * request.pageSize;
    final int pageEnd = pageOffset + request.pageSize;
    final List<VideoDiscoveryItem> pageItems = mergedWindow
        .skip(pageOffset)
        .take(request.pageSize)
        .toList(growable: false);
    hasMore = hasMore || mergedWindow.length > pageEnd;
    return ProviderBatchResult<VideoDiscoveryPage>(
      items: successfulProviders == 0
          ? const <VideoDiscoveryPage>[]
          : <VideoDiscoveryPage>[
              VideoDiscoveryPage(
                items: pageItems,
                page: request.page,
                hasMore: hasMore,
              ),
            ],
      failures: _deduplicateFailures(failures),
      successfulProviderCount: successfulProviders,
    );
  }

  List<VideoDiscoveryItem> _prepareProviderItems(
    _ProviderResponse response,
    VideoDiscoveryRequest request,
  ) {
    final List<VideoDiscoveryItem> items = <VideoDiscoveryItem>[
      for (final VideoDiscoveryPage page in response.pages) ...page.items,
    ];
    if (request.isSearch) {
      items.removeWhere(
        (VideoDiscoveryItem item) => !_matchesSearchFilters(item, request),
      );
    }
    return items;
  }

  /// 按发现项的主身份读取发现域详情。该入口不重新模糊搜索；返回的 lookup 仍属于
  /// 发现域；MAL 交叉 ID 与 TMDB 类型化 ID 可直接传给下载导入后的刮削。
  Future<VideoMetadataWork?> loadDetails(VideoDiscoveryItem item) async {
    if (_closed) return item.metadataWork;
    final List<VideoMetadataWork> works = <VideoMetadataWork>[
      for (final VideoMetadataWork? work
          in await Future.wait(<Future<VideoMetadataWork?>>[
        for (final VideoMetadataLookup lookup in await _detailLookups(item))
          _fetchDetails(lookup),
      ]))
        if (work != null) work,
    ];
    if (works.isEmpty) return item.metadataWork;
    final bool anime =
        item.reference.discoveryCategory == VideoDiscoveryCategory.anime;
    works.sort(
      (VideoMetadataWork a, VideoMetadataWork b) => _primaryRank(
        a.provider.name,
        anime: anime,
      ).compareTo(_primaryRank(b.provider.name, anime: anime)),
    );
    // 所有补充源统一走引擎的有序合并（与刮削协调器同一套规则）：简介 / 类型按
    // 资料语言选来源，人物跨源按人名 / 原名识别同一人。写法桥在合并前从全部来源
    // 一次收齐（AniList 同一条人物同时带罗马字与原文名），每一步合并共用，身份
    // 判定才不依赖来源排序（BUG-2797）。
    final VideoMetadataCreditNameBridge creditNames =
        VideoMetadataCreditNameBridge.fromWorks(works);
    VideoMetadataWork merged = works.first;
    for (final VideoMetadataWork supplement in works.skip(1)) {
      merged = supplementVideoMetadata(
        merged,
        supplement,
        preferredLanguage: _metadataLocale,
        creditNames: creditNames,
      );
    }
    return _withSourceTitlesAsAliases(merged, works);
  }

  /// 「整套下载」：[item] 所在系列的全部剧集与剧场版（见 `video_franchise.dart`）。
  ///
  /// TMDB collection（要 key）与 MAL 关联链（不要 key，只对动画走）两份合并；
  /// 两个来源都不可用返回 null。单个来源失败只记诊断、不拖垮另一个，但合并结果
  /// 标 [VideoFranchise.truncated]——少了一个来源的清单不能当成完整系列
  /// （BUG-2936）。
  Future<VideoFranchise?> loadFranchise(VideoDiscoveryItem item) async {
    if (_closed) return null;
    bool failed = false;
    VideoFranchise? tmdb;
    for (final VideoDiscoveryProvider provider in _providers) {
      if (provider is VideoFranchiseSource) {
        final _FranchiseAttempt attempt = await _guardFranchise(
          'tmdb',
          () => resolveVideoFranchise(provider as VideoFranchiseSource, item),
        );
        tmdb = attempt.franchise;
        failed |= attempt.failed;
        break;
      }
    }
    VideoFranchise? mal;
    final VideoMetadataProvider? malProvider =
        _metadataProviders[VideoMetadataProviderKind.mal];
    if (malProvider is MalVideoMetadataProvider &&
        item.reference.discoveryCategory == VideoDiscoveryCategory.anime) {
      final _FranchiseAttempt attempt = await _guardFranchise(
        'mal',
        () => resolveMalFranchise(_MalFranchiseSource(malProvider), item),
      );
      mal = attempt.franchise;
      failed |= attempt.failed;
    }
    // 动画的剧集以 MAL 为准：TMDB 把一部动画按「整部剧（含全部季）」收，MAL 按
    // 每季一个作品收——两边都进清单，同一批集会被整部剧和分季重复下载。
    if (tmdb != null && mal != null && mal.series.isNotEmpty) {
      tmdb = VideoFranchise(
        name: tmdb.name,
        series: const <VideoDiscoveryItem>[],
        movies: tmdb.movies,
        truncated: tmdb.truncated,
      );
    }
    final VideoFranchise? merged =
        mergeVideoFranchises(<VideoFranchise?>[tmdb, mal]);
    if (merged == null || !failed) return merged;
    return VideoFranchise(
      name: merged.name,
      series: merged.series,
      movies: merged.movies,
      truncated: true,
      more: merged.more,
    );
  }

  Future<_FranchiseAttempt> _guardFranchise(
    String source,
    Future<VideoFranchise?> Function() body,
  ) async {
    try {
      return (franchise: await body(), failed: false);
    } on Object catch (error, stack) {
      engineLog.logDiagnostic(
        'VideoDiscoveryService.loadFranchise.$source',
        '$error\n$stack',
      );
      return (franchise: null, failed: true);
    }
  }

  Future<List<VideoMetadataLookup>> _detailLookups(
    VideoDiscoveryItem item,
  ) async {
    final VideoMediaReference reference = item.reference;
    final Map<VideoMetadataProviderKind, VideoMetadataLookup> lookups =
        <VideoMetadataProviderKind, VideoMetadataLookup>{};
    final VideoMetadataLookup? confirmed = item.confirmedLookup;
    if (confirmed != null) lookups[confirmed.provider] = confirmed;
    void add(VideoMetadataProviderKind provider, Object? id) {
      final String value = id?.toString().trim() ?? '';
      if (value.isEmpty) return;
      lookups.putIfAbsent(
        provider,
        () => VideoMetadataLookup(
          provider: provider,
          externalId: value,
          mediaKind: reference.mediaKind,
        ),
      );
    }

    add(VideoMetadataProviderKind.mal, reference.externalIds['mal']);
    add(VideoMetadataProviderKind.anilist, reference.anilistId);
    add(VideoMetadataProviderKind.tmdb, reference.tmdbId);
    if (!lookups.containsKey(VideoMetadataProviderKind.tmdb)) {
      final VideoMetadataLookup? tmdb = await _tmdbLookupFromIdentityMap(item);
      if (tmdb != null) lookups[VideoMetadataProviderKind.tmdb] = tmdb;
    }
    return lookups.values.toList(growable: false);
  }

  /// 动画发现条目（AniList 季度 / 热门、MAL 搜索）没有 TMDB id，而 MAL /
  /// AniList 的简介只有英文：资料语言不是英文时，按条目的 MAL id 查 Fribb
  /// 交叉引用补一个 TMDB lookup，详情合并才有资料语言的简介可选。
  ///
  /// 只认**唯一明确**的映射（跨站映射规则）：同形态命名空间里只有一个 TMDB id；
  /// 剧集还必须落在 TMDB 第 1 季开头——第 2 季以后的作品在 TMDB 是同一部剧的
  /// 后续季，剧级简介 / 译名会把这一季的标题与介绍换成整部剧的，宁可保留英文。
  /// 只查**本地**索引、不在详情路径上等下载：索引还没有时先返回 null（详情照常
  /// 出英文），同时在后台触发刷新，完成后 [detailsUpdates] 通知界面重取。
  /// 索引不可用（离线 / 下载失败）静默不补：详情补充是加法。
  Future<VideoMetadataLookup?> _tmdbLookupFromIdentityMap(
    VideoDiscoveryItem item,
  ) async {
    final AnimeTmdbCrossReference? crossReference = _crossReference;
    if (crossReference == null) return null;
    if (item.reference.discoveryCategory != VideoDiscoveryCategory.anime) {
      return null;
    }
    final String? language = _metadataLocale;
    if (language == null || _primarySubtag(language) == 'en') return null;
    final VideoMetadataProvider? tmdb =
        _metadataProviders[VideoMetadataProviderKind.tmdb];
    if (tmdb == null || !tmdb.isAvailable) return null;
    final int? malId = _parseId(item.reference.externalIds['mal']);
    if (malId == null || malId <= 0) return null;
    final List<AnimeIdentityEntry>? entries;
    try {
      entries = await crossReference.entriesForMal(malId);
    } on Object catch (error) {
      engineLog.logDiagnostic(
        'VideoDiscoveryService.identityMap',
        '$error',
      );
      return null;
    }
    // 缺索引就后台拉、有索引就按周检查；两种都不等。
    unawaited(crossReference.refreshIfStale());
    if (entries == null) return null;
    final VideoMetadataMediaKind kind = item.reference.mediaKind;
    return tmdbLookupFromIdentityEntries(entries, kind: kind);
  }

  Future<VideoMetadataWork?> _fetchDetails(VideoMetadataLookup lookup) async {
    final VideoMetadataProvider? provider = _metadataProviders[lookup.provider];
    if (provider == null || !provider.isAvailable) return null;
    try {
      return await provider.fetchWork(lookup);
    } on Object {
      // 详情补充是加法；一个补源失败不能抹掉主源或发现摘要。
      return null;
    }
  }

  bool _supportsRequest(
    VideoDiscoveryProvider provider,
    VideoDiscoveryRequest request,
  ) {
    final VideoDiscoveryCapabilities capabilities = provider.capabilities;
    final VideoDiscoveryCategory? category = request.category;
    if (category != null && !capabilities.categories.contains(category)) {
      return false;
    }
    if (request.isSearch) {
      if (_searchProviderIds != null &&
          !_searchProviderIds.contains(provider.id)) {
        return false;
      }
      if (!capabilities.supportsSearch) return false;
      return true;
    }
    return capabilities.feeds.contains(request.feed);
  }

  Future<_ProviderResponse> _invoke(
    VideoDiscoveryProvider provider,
    VideoDiscoveryRequest request,
  ) async {
    try {
      final ProviderBatchResult<VideoDiscoveryPage> result = request.isSearch
          ? await provider.search(request)
          : await provider.discover(request);
      return _ProviderResponse(provider: provider, result: result);
    } on Object catch (error) {
      return _ProviderResponse(
        provider: provider,
        result: ProviderBatchResult<VideoDiscoveryPage>.failure(
          ExternalProviderFailure.fromException(
            providerId: provider.id,
            operation: request.isSearch ? 'search' : 'discover',
            error: error,
          ),
        ),
      );
    }
  }

  /// Rebuilds the provider's cumulative prefix before slicing the aggregate
  /// page. Fetching only provider page N would permanently discard each
  /// provider's unconsumed page N-1 tail after round-robin merge/dedup.
  Future<_ProviderResponse> _invokeWindow(
    VideoDiscoveryProvider provider,
    VideoDiscoveryRequest request,
  ) async {
    final int lastProviderPage =
        provider.capabilities.supportsPaging ? request.page : 1;
    final List<VideoDiscoveryPage> pages = <VideoDiscoveryPage>[];
    final List<ExternalProviderFailure> failures = <ExternalProviderFailure>[];
    bool succeeded = false;
    bool hasMore = false;
    for (int page = 1; page <= lastProviderPage; page++) {
      final _ProviderResponse response = await _invoke(
        provider,
        _requestAtPage(request, page),
      );
      failures.addAll(response.result.failures);
      if (response.result.successfulProviderCount > 0) succeeded = true;
      pages.addAll(response.pages);
      final bool responseHasMore = response.pages.any(
        (VideoDiscoveryPage providerPage) => providerPage.hasMore,
      );
      if (response.result.successfulProviderCount == 0) break;
      hasMore = responseHasMore;
      if (!hasMore) break;
    }
    return _ProviderResponse(
      provider: provider,
      result: ProviderBatchResult<VideoDiscoveryPage>(
        items: pages,
        failures: failures,
        successfulProviderCount: succeeded ? 1 : 0,
      ),
      hasMore: hasMore,
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (!_closesProviders) return;
    for (final VideoDiscoveryProvider provider in _providers) {
      provider.close();
    }
    for (final VideoMetadataProvider provider in _metadataProviders.values) {
      provider.close();
    }
    final AnimeTmdbCrossReference? crossReference = _crossReference;
    if (crossReference is AnimeTmdbCrossReferenceStore) crossReference.close();
  }
}

/// 跨来源身份合并。强 ID 严格优先：同一命名空间取值冲突直接否决，取值相同直接
/// 合并；只有在双方没有任何共享 ID 时，才退到「聚合媒体类型不冲突 + 规范化标题
/// 相交 + 非空年份相同」的弱匹配。AniList 会把部分单集 ONA 标成 TV，而
/// TMDB 将同一作品标成电影；搜索摘要不保证携带集数，集数缺失时聚合类型判为未知，
/// 未知与任何类型都不算冲突（见 [_aggregationKind]）。
///
/// [preferredLanguage]（资料语言，BCP-47）决定合并卡片的简介取哪个来源：见
/// [_MergedDiscoveryItem.build]。
List<VideoDiscoveryItem> mergeVideoDiscoveryItems(
  Iterable<VideoDiscoveryItem> items, {
  required VideoDiscoveryRequest request,
  String? preferredLanguage,
}) {
  final List<_MergedDiscoveryItem> groups = <_MergedDiscoveryItem>[];
  for (final VideoDiscoveryItem item in items) {
    _MergedDiscoveryItem? match;
    for (final _MergedDiscoveryItem group in groups) {
      if (group.canMerge(item)) {
        match = group;
        break;
      }
    }
    if (match == null) {
      groups.add(_MergedDiscoveryItem(item));
    } else {
      match.add(item);
    }
  }
  final List<VideoDiscoveryItem> merged = <VideoDiscoveryItem>[
    for (final _MergedDiscoveryItem group in groups)
      group.build(preferredLanguage: preferredLanguage),
  ];
  if (request.sort == VideoDiscoverySort.rating) {
    merged.sort(
      (VideoDiscoveryItem a, VideoDiscoveryItem b) =>
          (b.score ?? -1).compareTo(a.score ?? -1),
    );
  } else if (request.sort == VideoDiscoverySort.releaseDate) {
    merged.sort(
      (VideoDiscoveryItem a, VideoDiscoveryItem b) =>
          (b.releaseDate ?? '').compareTo(a.releaseDate ?? ''),
    );
  }
  return List<VideoDiscoveryItem>.unmodifiable(merged);
}

class _MergedDiscoveryItem {
  _MergedDiscoveryItem(VideoDiscoveryItem item)
      : _items = <VideoDiscoveryItem>[item];

  final List<VideoDiscoveryItem> _items;

  /// 按证据强度从强到弱判断：
  /// 1. 任一共同命名空间取值冲突 -> 否决（强 ID 说「不是同一个作品」）。
  /// 2. 任一共同命名空间取值相同 -> 合并（强 ID 说「就是同一个作品」）。此时
  ///    不再过任何基于可选字段的启发式闸门 —— 集数、时长这类字段各 adapter
  ///    填充不对称，没有资格推翻已经对上的 ID。
  /// 3. 没有共享 ID 时才退到弱匹配：聚合媒体类型不冲突 + 非空年份相同 +
  ///    规范化标题相交。
  bool canMerge(VideoDiscoveryItem candidate) {
    final Map<String, String> right = _strongIdentities(candidate.reference);
    final List<Map<String, String>> lefts = <Map<String, String>>[
      for (final VideoDiscoveryItem existing in _items)
        _strongIdentities(existing.reference),
    ];
    for (final Map<String, String> left in lefts) {
      if (_hasNamespaceConflict(left, right)) return false;
    }
    for (final Map<String, String> left in lefts) {
      if (left.keys.any(
        (String namespace) => right[namespace] == left[namespace],
      )) {
        return true;
      }
    }
    for (final VideoDiscoveryItem existing in _items) {
      if (_conflictingAggregationKinds(existing, candidate)) return false;
    }
    for (final VideoDiscoveryItem existing in _items) {
      final int? leftYear = existing.reference.year;
      final int? rightYear = candidate.reference.year;
      if (leftYear == null || rightYear == null || leftYear != rightYear) {
        continue;
      }
      final Set<String> leftTitles = _normalizedTitles(existing);
      final Set<String> rightTitles = _normalizedTitles(candidate);
      if (leftTitles.any(rightTitles.contains)) return true;
    }
    return false;
  }

  void add(VideoDiscoveryItem item) => _items.add(item);

  VideoDiscoveryItem build({String? preferredLanguage}) {
    final bool anime = _items.any(
      (VideoDiscoveryItem item) =>
          item.reference.discoveryCategory == VideoDiscoveryCategory.anime,
    );
    // 组内只要有一条被判定为电影身份，整组就按电影排序（不依赖 _items 的顺序）。
    final bool movieAggregation = _items.any(
      (VideoDiscoveryItem item) =>
          _aggregationKind(item) == VideoMetadataMediaKind.movie,
    );
    final List<VideoDiscoveryItem> ranked = List<VideoDiscoveryItem>.of(_items)
      ..sort((VideoDiscoveryItem a, VideoDiscoveryItem b) {
        // When an anime provider calls a single long-form work TV/ONA while a
        // movie database calls it a movie, keep the movie identity as primary.
        // This makes the merged card open/scrape as a movie, matching the
        // MoviePilot-style result users see, while retaining the anime ids.
        if (movieAggregation) {
          const VideoMetadataMediaKind movie = VideoMetadataMediaKind.movie;
          final int kindRank = (a.reference.mediaKind == movie ? 0 : 1)
              .compareTo(b.reference.mediaKind == movie ? 0 : 1);
          if (kindRank != 0) return kindRank;
        }
        return _primaryRank(
          a.reference.providerId,
          anime: anime,
        ).compareTo(_primaryRank(b.reference.providerId, anime: anime));
      });
    final VideoDiscoveryItem primary = ranked.first;
    final Map<String, String> externalIds = <String, String>{};
    final List<VideoMetadataId> metadataIds = <VideoMetadataId>[];
    final Set<String> metadataIdKeys = <String>{};
    final Set<String> aliases = <String>{};
    for (final VideoDiscoveryItem item in ranked) {
      final VideoMediaReference reference = item.reference;
      externalIds.addAll(reference.externalIds);
      void addExternal(String namespace, Object? value) {
        final String normalized = value?.toString().trim() ?? '';
        if (normalized.isNotEmpty) {
          externalIds.putIfAbsent(namespace, () => normalized);
        }
      }

      addExternal('tmdb', reference.tmdbId);
      addExternal('imdb', reference.imdbId);
      addExternal('tvdb', reference.tvdbId);
      addExternal('anidb', reference.anidbId);
      addExternal('anilist', reference.anilistId);
      addExternal('bangumi', reference.bangumiId);
      aliases.add(reference.title);
      if (reference.originalTitle case final String original) {
        aliases.add(original);
      }
      aliases.addAll(reference.aliases);
      for (final VideoMetadataId id
          in item.metadataWork?.ids ?? const <VideoMetadataId>[]) {
        final String key = '${id.type.toLowerCase()}:${id.value}';
        if (metadataIdKeys.add(key)) metadataIds.add(id);
      }
      aliases.addAll(item.metadataWork?.aliases ?? const <String>[]);
    }
    final VideoMetadataWork? primaryWork = primary.metadataWork;
    final VideoMetadataWork? mergedWork = primaryWork?.copyWith(
      aliases: aliases
          .where((String value) => value != primary.reference.title)
          .toList(growable: false),
      ids: metadataIds,
      genres: _uniqueStrings(
        ranked.expand((VideoDiscoveryItem item) => item.genres),
      ),
    );
    final VideoMediaReference reference = VideoMediaReference(
      providerId: primary.reference.providerId,
      mediaId: primary.reference.mediaId,
      mediaKind: primary.reference.mediaKind,
      discoveryCategory: anime
          ? VideoDiscoveryCategory.anime
          : primary.reference.discoveryCategory,
      title: primary.reference.title,
      originalTitle: primary.reference.originalTitle ??
          _firstNonEmpty(
            ranked.map(
              (VideoDiscoveryItem item) => item.reference.originalTitle,
            ),
          ),
      aliases: aliases
          .where((String value) => value != primary.reference.title)
          .toList(growable: false),
      year: primary.reference.year ??
          _firstValue(
            ranked.map((VideoDiscoveryItem item) => item.reference.year),
          ),
      season: primary.reference.season,
      episode: primary.reference.episode,
      anidbId: primary.reference.anidbId ?? _parseId(externalIds['anidb']),
      tmdbId: primary.reference.tmdbId ?? _parseId(externalIds['tmdb']),
      imdbId: primary.reference.imdbId ?? externalIds['imdb'],
      tvdbId: primary.reference.tvdbId ?? _parseId(externalIds['tvdb']),
      anilistId:
          primary.reference.anilistId ?? _parseId(externalIds['anilist']),
      bangumiId:
          primary.reference.bangumiId ?? _parseId(externalIds['bangumi']),
      externalIds: externalIds,
    );
    return VideoDiscoveryItem(
      reference: reference,
      overview: _pickOverview(ranked, preferredLanguage),
      posterUrl: primary.posterUrl ??
          _firstNonEmpty(
            ranked.map((VideoDiscoveryItem item) => item.posterUrl),
          ),
      backdropUrl: primary.backdropUrl ??
          _firstNonEmpty(
            ranked.map((VideoDiscoveryItem item) => item.backdropUrl),
          ),
      score: primary.score ??
          _firstValue(ranked.map((VideoDiscoveryItem item) => item.score)),
      releaseDate: primary.releaseDate ??
          _firstNonEmpty(
            ranked.map((VideoDiscoveryItem item) => item.releaseDate),
          ),
      genres: _uniqueStrings(
        ranked.expand((VideoDiscoveryItem item) => item.genres),
      ),
      metadataWork: mergedWork,
      confirmedLookup: primary.confirmedLookup,
    );
  }
}

/// 条目在聚合层的媒体类型；`null` 表示**未知**。
///
/// 动画专用来源可能把单集 ONA/OVA 标成 TV，TMDB 把同一作品标成电影，只有拿到
/// 集数才能判定谁对。而集数是可选字段、各 adapter 填充不对称（搜索摘要普遍不带
/// 集数），所以集数缺失时必须承认「不知道」，不能默认成 TV —— 默认成 TV 会把本该
/// 合并的单集作品重新拆成两张卡（BUG-1531 的反面）。未知与任何类型都不算冲突。
///
/// 唯一的例外是**正在放送**：电影没有「放送中」这个状态（TMDB 电影状态只有
/// released / post production 等），一部 TV/ONA 正在逐集播出，就足以断定它是
/// 剧集。修前集数未知的放送中动画会被同名同年的 TMDB 电影身份弱匹配吞掉，整组
/// 按电影下载、整理（BUG-2760）。
VideoMetadataMediaKind? _aggregationKind(VideoDiscoveryItem item) {
  if (item.reference.mediaKind == VideoMetadataMediaKind.movie) {
    return VideoMetadataMediaKind.movie;
  }
  if (item.reference.discoveryCategory == VideoDiscoveryCategory.anime) {
    final int? episodeCount = item.metadataWork?.episodeCount;
    if (episodeCount == null &&
        item.metadataWork?.airingStatus == VideoAiringStatus.airing) {
      return item.reference.mediaKind;
    }
    if (episodeCount == null) return null;
    if (episodeCount == 1) return VideoMetadataMediaKind.movie;
  }
  return item.reference.mediaKind;
}

/// 只有双方聚合类型都已知且不同才算冲突；任一侧未知都不足以否决弱匹配。
bool _conflictingAggregationKinds(
  VideoDiscoveryItem left,
  VideoDiscoveryItem right,
) {
  final VideoMetadataMediaKind? leftKind = _aggregationKind(left);
  final VideoMetadataMediaKind? rightKind = _aggregationKind(right);
  if (leftKind == null || rightKind == null) return false;
  return leftKind != rightKind;
}

Map<String, String> _strongIdentities(VideoMediaReference reference) {
  final Map<String, String> result = <String, String>{};
  void add(String namespace, Object? raw) {
    final String value = raw?.toString().trim().toLowerCase() ?? '';
    if (value.isNotEmpty) result[namespace] = value;
  }

  add('imdb', reference.imdbId);
  add('tmdb-${reference.mediaKind.name}', reference.tmdbId);
  add('tvdb', reference.tvdbId);
  add('anidb', reference.anidbId);
  add('anilist', reference.anilistId);
  add('bangumi', reference.bangumiId);
  for (final MapEntry<String, String> entry in reference.externalIds.entries) {
    final String rawNamespace = entry.key.trim().toLowerCase();
    final String namespace = rawNamespace == 'tmdb'
        ? 'tmdb-${reference.mediaKind.name}'
        : rawNamespace;
    add(namespace, entry.value);
  }
  add(
    '${reference.providerId.trim().toLowerCase()}-${reference.mediaKind.name}',
    reference.mediaId,
  );
  return result;
}

bool _hasNamespaceConflict(
  Map<String, String> left,
  Map<String, String> right,
) {
  for (final String namespace in left.keys) {
    final String? other = right[namespace];
    if (other != null && other != left[namespace]) return true;
  }
  return false;
}

Set<String> _normalizedTitles(VideoDiscoveryItem item) => <String>{
      item.reference.title,
      if (item.reference.originalTitle case final String original) original,
      ...?item.metadataWork?.aliases,
    }
        .map(TitleNormalizer.normalize)
        .where((String value) => value.isNotEmpty)
        .toSet();

int _primaryRank(String providerId, {required bool anime}) {
  final String provider = providerId.trim().toLowerCase();
  if (anime) {
    return switch (provider) {
      'mal' => 0,
      'anilist' => 1,
      'tmdb' => 2,
      _ => 10,
    };
  }
  return switch (provider) {
    'tmdb' => 0,
    'anilist' => 2,
    _ => 10,
  };
}

/// 发现详情的别名池收齐各来源的标题：下载搜索与去重靠 title / original /
/// aliases 三处命中，补充源的译名（TMDB 中文名、AniList 原名）不能在合并里丢掉。
VideoMetadataWork _withSourceTitlesAsAliases(
  VideoMetadataWork merged,
  Iterable<VideoMetadataWork> sources,
) {
  final String title = merged.title.trim();
  final List<String> aliases = _uniqueStrings(<String>[
    ...merged.aliases,
    for (final VideoMetadataWork source in sources) ...<String>[
      source.title,
      if (source.originalTitle case final String original) original,
    ],
  ]).where((String alias) => alias != title).toList(growable: false);
  return merged.copyWith(aliases: aliases);
}

List<VideoDiscoveryItem> _roundRobin(List<List<VideoDiscoveryItem>> sources) {
  final List<VideoDiscoveryItem> result = <VideoDiscoveryItem>[];
  int index = 0;
  while (sources.any(
    (List<VideoDiscoveryItem> source) => index < source.length,
  )) {
    for (final List<VideoDiscoveryItem> source in sources) {
      if (index < source.length) result.add(source[index]);
    }
    index++;
  }
  return result;
}

bool _matchesSearchFilters(
  VideoDiscoveryItem item,
  VideoDiscoveryRequest request,
) {
  if (request.year != null && item.reference.year != request.year) {
    return false;
  }
  final String requestedGenre = _canonicalDiscoveryGenre(request.genre);
  if (requestedGenre.isNotEmpty &&
      !item.genres.map(_canonicalDiscoveryGenre).contains(requestedGenre)) {
    return false;
  }
  final String requestedRegion = _canonicalRegion(request.region);
  if (requestedRegion.isNotEmpty) {
    final Iterable<String> countries =
        item.metadataWork?.countries ?? const <String>[];
    if (!countries.map(_canonicalRegion).contains(requestedRegion)) {
      return false;
    }
  }
  return true;
}

String _canonicalDiscoveryGenre(String? genre) {
  final String normalized = genre
          ?.trim()
          .toLowerCase()
          .replaceAll(RegExp(r'[_-]+'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ') ??
      '';
  return switch (normalized) {
    'sci fi' || 'scifi' => 'science fiction',
    _ => normalized,
  };
}

String _canonicalRegion(String? region) {
  final String normalized = region?.trim().toLowerCase() ?? '';
  return switch (normalized) {
    'china' || '中国' || '中國' => 'CN',
    'japan' || '日本' => 'JP',
    'south korea' || 'korea' || '韩国' || '韓國' => 'KR',
    'united states' ||
    'united states of america' ||
    'usa' ||
    '美国' ||
    '美國' =>
      'US',
    'united kingdom' || 'great britain' || '英国' || '英國' => 'GB',
    'france' || '法国' || '法國' => 'FR',
    _ => normalized.toUpperCase(),
  };
}

List<ExternalProviderFailure> _deduplicateFailures(
  Iterable<ExternalProviderFailure> failures,
) {
  final Set<String> seen = <String>{};
  return <ExternalProviderFailure>[
    for (final ExternalProviderFailure failure in failures)
      if (seen.add(
        '${failure.providerId}:${failure.operation}:${failure.kind.name}',
      ))
        failure,
  ];
}

List<String> _uniqueStrings(Iterable<String> values) {
  final Set<String> seen = <String>{};
  return <String>[
    for (final String value in values)
      if (value.trim().isNotEmpty && seen.add(value.trim())) value.trim(),
  ];
}

T? _firstValue<T>(Iterable<T?> values) {
  for (final T? value in values) {
    if (value != null) return value;
  }
  return null;
}

String? _firstNonEmpty(Iterable<String?> values) {
  for (final String? value in values) {
    if (value?.trim().isNotEmpty == true) return value!.trim();
  }
  return null;
}

int? _parseId(String? value) => int.tryParse(value ?? '');

String? _primarySubtag(String? tag) {
  final String trimmed = tag?.trim().toLowerCase() ?? '';
  if (trimmed.isEmpty) return null;
  final String primary = trimmed.split(RegExp(r'[-_]')).first;
  return primary.isEmpty ? null : primary;
}

/// 合并卡片的简介：组内按主源顺序找**资料语言**的简介（TMDB 按资料语言请求；
/// MAL / AniList 恒英文，见 [videoMetadataTextMatchesLanguage]）；都不是资料
/// 语言时才回到「主源有字用主源、否则第一条非空」。修前一律主源优先，动画卡片
/// 的主源是 MAL / AniList，于是中文用户在同组 TMDB 有中文简介时仍看到英文。
String? _pickOverview(
  List<VideoDiscoveryItem> ranked,
  String? preferredLanguage,
) {
  if (preferredLanguage != null) {
    for (final VideoDiscoveryItem item in ranked) {
      final String? overview = item.overview?.trim();
      if (overview == null || overview.isEmpty) continue;
      final VideoMetadataProviderKind? provider = _itemProvider(item);
      if (provider != null &&
          videoMetadataTextMatchesLanguage(provider, preferredLanguage)) {
        return overview;
      }
    }
  }
  return ranked.first.overview ??
      _firstNonEmpty(ranked.map((VideoDiscoveryItem item) => item.overview));
}

VideoMetadataProviderKind? _itemProvider(VideoDiscoveryItem item) {
  final VideoMetadataProviderKind? fromWork = item.metadataWork?.provider;
  if (fromWork != null) return fromWork;
  final String id = item.reference.providerId.trim().toLowerCase();
  for (final VideoMetadataProviderKind kind
      in VideoMetadataProviderKind.values) {
    if (kind.name == id) return kind;
  }
  return null;
}

/// Fribb 条目（同一 MAL id 的全部 AniDB 行）→ 唯一明确的 TMDB lookup。
///
/// 只在 [kind] 对应的 TMDB 命名空间里取 id（剧场版挂在剧特典季下的 tv id 不能
/// 当 /movie 用，BUG-2828）；去重后必须恰好一个 id。剧集另外要求至少一行落在
/// TMDB 第 1 季、集偏移 0——后续季在 TMDB 是同一部剧，剧级简介与译名不属于这
/// 一季。不满足任一条返回 null（宁可不补，不拿错的作品充数）。
@visibleForTesting
VideoMetadataLookup? tmdbLookupFromIdentityEntries(
  List<AnimeIdentityEntry> entries, {
  required VideoMetadataMediaKind kind,
}) {
  final List<AnimeIdentityEntry> matching = <AnimeIdentityEntry>[
    for (final AnimeIdentityEntry entry in entries)
      if (entry.tmdbIdFor(kind) != null) entry,
  ];
  final Set<int> ids = <int>{
    for (final AnimeIdentityEntry entry in matching) entry.tmdbIdFor(kind)!,
  };
  if (ids.length != 1) return null;
  if (kind == VideoMetadataMediaKind.tv &&
      !matching.any(
        (AnimeIdentityEntry entry) =>
            (entry.tmdbSeason ?? 1) == 1 && (entry.tmdbEpisodeOffset ?? 0) == 0,
      )) {
    return null;
  }
  return VideoMetadataLookup(
    provider: VideoMetadataProviderKind.tmdb,
    externalId: '${ids.single}',
    mediaKind: kind,
  );
}

class _ProviderResponse {
  const _ProviderResponse({
    required this.provider,
    required this.result,
    this.hasMore = false,
  });

  final VideoDiscoveryProvider provider;
  final ProviderBatchResult<VideoDiscoveryPage> result;
  final bool hasMore;

  List<VideoDiscoveryPage> get pages => result.items;
}

VideoDiscoveryRequest _requestAtPage(VideoDiscoveryRequest request, int page) =>
    VideoDiscoveryRequest(
      category: request.category,
      feed: request.feed,
      query: request.query,
      page: page,
      pageSize: request.pageSize,
      sort: request.sort,
      year: request.year,
      genre: request.genre,
      region: request.region,
    );

/// MAL provider → 系列关联来源的薄适配。
/// 一个系列来源跑一次的结果：`failed` 区分「来源没有这部的数据」（null）与
/// 「来源出错」——后者让合并清单标没走完。
typedef _FranchiseAttempt = ({VideoFranchise? franchise, bool failed});

class _MalFranchiseSource implements VideoFranchiseRelationSource {
  _MalFranchiseSource(this._provider);

  final MalVideoMetadataProvider _provider;

  @override
  Future<MalRelatedWorks?> fetchRelatedWorks(String malId) =>
      _provider.fetchRelatedWorks(malId);

  @override
  Future<List<VideoMetadataWork>> searchAnime(String title) async {
    final List<VideoMetadataWork> works = <VideoMetadataWork>[];
    for (final VideoMetadataMediaKind kind in VideoMetadataMediaKind.values) {
      works.addAll(
        await _provider.search(
          VideoMetadataSearchRequest(title: title, mediaKind: kind, limit: 5),
        ),
      );
    }
    return works;
  }
}
