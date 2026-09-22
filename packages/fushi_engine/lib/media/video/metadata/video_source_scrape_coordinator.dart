/// 视频来源规范刮削协调器：按作品识别、抓取、写 v77/兼容投影并安全导出 NFO/图片。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:meta/meta.dart';
import 'package:drift/drift.dart' show Value;
import 'package:http/http.dart' as http;
import 'package:fushi_engine/media/video/metadata/anidb_file_identity_store.dart';
import 'package:fushi_engine/media/video/metadata/anidb_hash_identity_service.dart';
import 'package:fushi_engine/media/video/metadata/anidb_udp_file_client.dart';
import 'package:fushi_engine/media/video/metadata/mal_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/tmdb_episode_matcher.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_transport.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/anidb_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_asset_downloader.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_database_store.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_languages.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_merge.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_nfo_builder.dart';
import 'package:fushi_engine/media/video/metadata/video_nfo_reader.dart';
import 'package:fushi_engine/media/video/metadata/video_sidecar_artifact_store.dart';
import 'package:fushi_engine/media/video/metadata/video_sidecar_target_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_sidecar_writer.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi_engine/media/video/scraper/filename_parser.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:fushi_engine/media/video/metadata/anidb_title_catalog.dart';
import 'package:fushi_engine/media/video/metadata/anime_episode_relations.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/collections/collection_asset_reclaim.dart';
import 'package:fushi_engine/media/cover_file_writer.dart';
import 'package:fushi_engine/media/video/metadata/anime_identity_mapping.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_json.dart'
    show metadataUniqueStrings;
import 'package:fushi_engine/media/video/metadata/anime_offline_identity_resolver.dart';
import 'package:fushi_engine/media/video/scraper/scrape_identifier_words.dart';
import 'package:fushi_engine/media/video/scraper/scraper_types.dart';

class VideoSourceScrapeCoordinator
    implements
        VideoSourceScrapeRunner,
        VideoSourceScrapeInterruptible,
        VideoSourceScrapeManualBinding,
        VideoSourceScrapeEpisodeOrdering {
  /// 默认装配：哈希服务与离线 id 接力**共用同一份** Fribb 映射表（以前各自
  /// 下载、各解一份 16 MB JSON），并接上 `anidb_file_identities` 持久层（v106）。
  factory VideoSourceScrapeCoordinator({
    required FushiDatabase database,
    required VideoSourceScrapeGlobalConfig config,
    VideoMetadataProviderRegistry? registry,
    VideoMetadataProviderKind? primaryProvider,
    AnidbHashIdentityService? hashIdentityService,
    VideoMetadataAssetDownloader? assetDownloader,
    AnimeIdentityMapping? identityMapping,
    AnimeOfflineIdentityResolver? offlineIdentityResolver,
    bool enableOfflineTitleIndex = false,
    AnimeEpisodeRelationsCatalog? episodeRelations,
    VideoMetadataProviderRegistry Function(String locale)?
        localeRegistryFactory,
    Future<void> Function(VideoScrapedWorkNotice notice)? onWorkScraped,
    AiVideoIdentityDecider? aiIdentityDecider,
  }) {
    final AnimeIdentityMapping? sharedMapping = identityMapping ??
        (enableOfflineTitleIndex ? AnimeIdentityMapping() : null);
    final VideoMetadataProviderRegistry effectiveRegistry =
        registry ?? _createRegistry(config);
    // 集信息首选 AniDB HTTP anime XML（Shoko：一次拿全集播出日），UDP EPISODE 兜底。
    Future<AnidbEpisodeInfo?> episodeInfoFromXml(
        {required int animeId, required int episodeId}) async {
      final VideoMetadataProvider? provider =
          effectiveRegistry.provider(VideoMetadataProviderKind.anidb);
      if (provider is! AniDbVideoMetadataProvider) return null;
      return provider.episodeInfo(animeId: animeId, episodeId: episodeId);
    }
    return VideoSourceScrapeCoordinator._(
      database: database,
      config: config,
      registry: effectiveRegistry,
      primaryProvider: primaryProvider,
      hashIdentityService: hashIdentityService,
      resolvedHashIdentityService: hashIdentityService ??
          AnidbHashIdentityService(
              enabled: config.hashEnabled,
              config: config.anidbUdpConfig,
              mapping: sharedMapping,
              episodeInfoSource: episodeInfoFromXml,
              store: AnidbFileIdentityDatabaseStore(database)),
      assetDownloader: assetDownloader,
      identityMapping: identityMapping,
      resolvedIdentityMapping: sharedMapping,
      offlineIdentityResolver: offlineIdentityResolver,
      enableOfflineTitleIndex: enableOfflineTitleIndex,
      episodeRelations: episodeRelations,
      localeRegistryFactory: localeRegistryFactory,
      onWorkScraped: onWorkScraped,
      aiIdentityDecider: aiIdentityDecider,
    );
  }

  VideoSourceScrapeCoordinator._({
    required this.database,
    required this.config,
    required VideoMetadataProviderRegistry? registry,
    required VideoMetadataProviderKind? primaryProvider,
    required AnidbHashIdentityService? hashIdentityService,
    required AnidbHashIdentityService resolvedHashIdentityService,
    required VideoMetadataAssetDownloader? assetDownloader,
    required AnimeIdentityMapping? identityMapping,
    required AnimeIdentityMapping? resolvedIdentityMapping,
    required AnimeOfflineIdentityResolver? offlineIdentityResolver,
    required bool enableOfflineTitleIndex,
    required AnimeEpisodeRelationsCatalog? episodeRelations,
    required VideoMetadataProviderRegistry Function(String locale)?
        localeRegistryFactory,
    required this.onWorkScraped,
    required this.aiIdentityDecider,
  })  : primaryProvider = primaryProvider ?? config.primaryProvider,
        _localeRegistryFactory = localeRegistryFactory ??
            ((String locale) => _createRegistry(config, locale: locale)),
        episodeRelations = episodeRelations ??
            (enableOfflineTitleIndex ? AnimeEpisodeRelationsCatalog() : null),
        _ownsEpisodeRelations = episodeRelations == null,
        registry = registry ?? _createRegistry(config),
        assetDownloader = assetDownloader ?? VideoMetadataAssetDownloader(),
        hashIdentityService = resolvedHashIdentityService,
        identityMapping = resolvedIdentityMapping,
        _ownsHashIdentityService = hashIdentityService == null,
        _ownsRegistry = registry == null,
        _ownsAssetDownloader = assetDownloader == null,
        _ownsIdentityMapping = identityMapping == null,
        _store = VideoMetadataDatabaseStore(database) {
    // 离线标题索引与 id 接力都要联网拉数据包（AniDB 标题包 / Fribb 表），所以
    // 默认关闭：只有生产装配点显式打开，或测试注入自己的 resolver，绝不让
    // 单测因为默认构造去下载 20MB 数据。
    this.offlineIdentityResolver = offlineIdentityResolver ??
        (enableOfflineTitleIndex
            ? AnimeOfflineIdentityResolver(
                catalog: AniDbTitleCatalog(),
                mapping: this.identityMapping!,
                ownsCatalog: true,
              )
            : null);
  }

  final FushiDatabase database;
  final VideoSourceScrapeGlobalConfig config;
  final VideoMetadataProviderRegistry registry;

  /// 全局默认主源；来源级 `provider_override` 可覆盖，见 [_sourceProvider]。
  final VideoMetadataProviderKind primaryProvider;
  final AnidbHashIdentityService hashIdentityService;
  final bool _ownsHashIdentityService;
  final VideoMetadataAssetDownloader assetDownloader;

  /// 跨站 id 映射（Fribb anime-lists）：TMDB 补充的 id 接力用；null = 不接力。
  final AnimeIdentityMapping? identityMapping;

  /// 离线标题索引阶段（设计稿 A2）：AniDB 标题包唯一精确命中 → Fribb 换 id；
  /// null = 跳过该阶段。
  late final AnimeOfflineIdentityResolver? offlineIdentityResolver;

  /// anime-relations 显式集区间重定向（设计稿 B）；null = 只按季集数累加。
  final AnimeEpisodeRelationsCatalog? episodeRelations;
  final bool _ownsEpisodeRelations;

  /// 每个作品最近一次解析出的成员 (季, 集) 覆盖，与 resolvedWorkCache 同键。
  final Map<String, AnidbAdditionalEpisodeBindings> _anidbAdditionalCache =
      <String, AnidbAdditionalEpisodeBindings>{};
  final Map<String, Map<String, AnidbEpisodeXref>> _anidbXrefCache =
      <String, Map<String, AnidbEpisodeXref>>{};
  final Map<String, Set<String>> _userVerifiedCache = <String, Set<String>>{};

  /// 合并预处理已识别过的文件（视频路径 → 结果），主循环按文件消费一次即删。
  final Map<String, AnidbHashIdentityResult> _preIdentified =
      <String, AnidbHashIdentityResult>{};
  final Map<String, Map<String, (int, int)>> _episodeOverridesCache =
      <String, Map<String, (int, int)>>{};
  final bool _ownsRegistry;
  final bool _ownsAssetDownloader;
  final bool _ownsIdentityMapping;
  final VideoMetadataDatabaseStore _store;

  /// 一个作品刮完（规范数据已落库、sidecar 已写）后的通知。
  ///
  /// 刮削本身**不做**字幕：它是全仓唯一解析出规范身份（AniDB/TMDB id + 原名）
  /// 的地方，而字幕搜索的准确率几乎完全取决于身份准不准。把「谁需要字幕」这个
  /// 事实播出去，由消费方（AppModel → VideoSubtitleBackfillService）决定要不要
  /// 补、按什么偏好补——刮削协调器不该长出网络字幕依赖，也不该被字幕失败拖慢。
  ///
  /// 回调抛出的异常会被吞掉并记进本次 run 的 warnings，绝不让补字幕影响刮削结论。
  final Future<void> Function(VideoScrapedWorkNotice notice)? onWorkScraped;

  /// 歧义候选的 AI 消解器；null = 不启用，歧义直接进人工确认 / 待确认（旧行为）。
  ///
  /// 只在 resolver 已经判定 ambiguous、候选已经取回之后被问一次，不新增任何资料
  /// 源请求；命中且置信度达到 [kAiVideoIdentityAutoAcceptConfidence] 才当作用户
  /// 选了那条候选，后续绑定 / 写库路径与人工确认完全相同。AI 故障一律吞成
  /// 「不采用」，绝不把刮削整体标失败。
  final AiVideoIdentityDecider? aiIdentityDecider;

  /// 同一目录、同一批候选只问一次 AI（键见 [AiVideoIdentityQuery.cacheKey]）；
  /// 值为 null 表示 AI 明确没给出唯一命中，同样不再重问。
  final Map<String, AiVideoIdentityDecision?> _aiIdentityCache =
      <String, AiVideoIdentityDecision?>{};

  /// 本趟 run 里 AI 已经失败过（网络 / 鉴权 / 超时）时记下 run id：同一趟余下的
  /// 歧义作品跳过 AI，免得每条都等满一次请求超时；下一趟 run 照常再试。
  int? _aiIdentityFailedRunId;

  final Set<int> _interruptedRunIds = <int>{};
  int? _activeRunId;

  /// 本趟刮削的来源级 provider 注册表与资料语言（v99 `metadata_locale`）。
  ///
  /// TMDB provider 的 `language` 是**构造期**参数，来源 locale 与全局不同时不能
  /// 复用同一个实例，所以这一趟临时建一套、跑完关掉。协调器同时只跑一趟
  /// （见 [_activeRunId]，run 生命周期本来就用单字段表达），所以作用域用字段承载
  /// 是与既有设计一致的；null = 跟随全局。
  VideoMetadataProviderRegistry? _scopedRegistry;
  String? _scopedLocale;

  /// 建「本趟的 provider 注册表」的工厂。生产装配就是 [_createRegistry]；测试注入
  /// 假工厂来断言这一趟到底拿到了哪个 locale——否则来源级 locale 是否真的传下去，
  /// 只能靠读代码判断。
  final VideoMetadataProviderRegistry Function(String locale)
      _localeRegistryFactory;

  /// 刮削管线内部一律用这个 getter 取 provider，别直接用 [registry]——后者是
  /// 全局 locale 的那套，只留给不写库的手动搜索。
  VideoMetadataProviderRegistry get _registry => _scopedRegistry ?? registry;

  /// 本趟刮削的有效资料语言（来源级覆盖 > 全局）。
  String get _locale => _scopedLocale ?? config.locale;

  static VideoMetadataProviderRegistry _createRegistry(
    VideoSourceScrapeGlobalConfig config, {
    String? locale,
  }) =>
      VideoMetadataProviderRegistry.production(config, locale: locale);

  /// 对刚完成下载导入的单个作品执行身份受控的刮削。
  ///
  /// [lookup] 来自发现页已确认的身份。MAL/TMDB lookup 锁定本次作品来源；
  /// 用户指定的身份失败时不回退到另一作品。
  /// provider hydration、规范数据库写入、NFO/图片 sidecar 与 run / artifact 审计
  /// 完整复用来源刮削管线。
  Future<SourceScrapeReport> scrapeImportedWork(
    VideoSourceScrapeWork work, {
    required VideoMetadataLookup lookup,
    VideoSourceScrapeCancellationToken? cancellationToken,
    VideoSourceScrapeProgressCallback? onProgress,
  }) =>
      scrapeSource(
        // 下载导入器给的单元恒带来源；无来源的元数据写入目标不该走到真刮这里。
        ArgumentError.checkNotNull(work.source, 'work.source'),
        cancellationToken:
            cancellationToken ?? VideoSourceScrapeCancellationToken(),
        onProgress: onProgress ?? (_) {},
        plannedWorks: <VideoSourceScrapeWork>[work],
        confirmedLookups: <String, VideoMetadataLookup>{
          work.stableKey: lookup,
        },
        runScope: 'work',
      );

  @override
  Future<List<VideoSourceScrapeConfirmationCandidate>> searchManualCandidates({
    SourceLibraryRow? source,
    required String workTitle,
    String? workStableKey,
    required String query,
  }) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) {
      return const <VideoSourceScrapeConfirmationCandidate>[];
    }
    // 作品可能已不在当前计划里（文件改名/移动/删除后标题漂移，BUG-1998）。
    // 搜索只需要「电影还是剧集」这一个参数：拿不到就双形态各搜一次再按身份
    // 去重合并，绝不让只读的候选搜索因为计划回查失败而整个抛异常。
    // [source] 为 null（互联客户端代 host 刮削，7b：本机没有这部作品的来源库）
    // 时同样走双形态搜索，provider 取全局主源。
    final VideoSourceScrapeWork? work = source == null
        ? null
        : await _plannedWorkOrNull(source, workTitle,
            workStableKey: workStableKey);
    final List<VideoMetadataLookup> explicit = parseExplicitVideoMetadataIds(
      <String>[trimmed],
      fallbackMediaKind:
          work == null ? VideoMetadataMediaKind.tv : _manualMediaKind(work),
    );
    final bool identityInput = explicit.isNotEmpty ||
        trimmed.contains('://') ||
        RegExp(r'^(?:mal|myanimelist|tmdb|anidb|aid)\s*[:=]',
                caseSensitive: false)
            .hasMatch(trimmed);
    final VideoMetadataProviderKind selected =
        source == null ? primaryProvider : await _sourceProvider(source);
    final List<VideoMetadataProviderKind> chain = _providerChain(selected);
    if (identityInput) {
      final VideoMetadataLookup? lookup =
          explicit.length == 1 ? explicit.single : null;
      // 手动给的 id 只要是可选生产主源（AniDB / MAL / TMDB）的就直取——与
      // resolver `_acceptsIdentity`、协调器 `acceptsCanonical` 同一判据。
      if (lookup == null ||
          !kSelectableVideoMetadataProviders.contains(lookup.provider) ||
          !RegExp(r'^[0-9]+$').hasMatch(lookup.externalId) ||
          (int.tryParse(lookup.externalId) ?? 0) <= 0) {
        throw const FormatException('Invalid video metadata work ID');
      }
      if (trimmed.contains('://') &&
          !<String>{'http', 'https'}.contains(Uri.tryParse(trimmed)?.scheme)) {
        throw const FormatException('Invalid video metadata work URL');
      }
      final VideoMetadataProvider? provider =
          _manualSearchProvider(lookup.provider);
      if (provider == null) {
        return const <VideoSourceScrapeConfirmationCandidate>[];
      }
      final VideoMetadataWork? result = await provider.fetchWork(lookup);
      return <VideoSourceScrapeConfirmationCandidate>[
        if (result != null)
          VideoSourceScrapeConfirmationCandidate(
              lookup: lookup.provider == VideoMetadataProviderKind.mal ||
                      lookup.provider == VideoMetadataProviderKind.anidb
                  ? VideoMetadataLookup(
                      provider: lookup.provider,
                      externalId: lookup.externalId,
                      mediaKind: result.kind)
                  : lookup,
              work: result),
      ];
    }
    final List<VideoMetadataMediaKind> kinds = work == null
        ? const <VideoMetadataMediaKind>[
            VideoMetadataMediaKind.tv,
            VideoMetadataMediaKind.movie,
          ]
        : <VideoMetadataMediaKind>[_manualMediaKind(work)];
    final List<VideoSourceScrapeConfirmationCandidate> candidates =
        <VideoSourceScrapeConfirmationCandidate>[];
    final Set<String> seenLookups = <String>{};
    for (final VideoMetadataProviderKind providerKind in chain) {
      final VideoMetadataProvider? provider =
          _manualSearchProvider(providerKind);
      if (provider == null) continue;
      try {
        for (final VideoMetadataMediaKind kind in kinds) {
          final List<VideoMetadataWork> results = await provider.search(
            VideoMetadataSearchRequest(title: trimmed, mediaKind: kind),
          );
          for (final VideoMetadataWork candidate in results) {
            if (_lookupForCandidate(candidate, provider.providerKind)
                case final VideoMetadataLookup lookup) {
              if (!seenLookups.add(
                  '${lookup.provider.name}:${lookup.mediaKind.name}:${lookup.externalId}')) {
                continue;
              }
              candidates.add(VideoSourceScrapeConfirmationCandidate(
                  lookup: lookup, work: candidate));
            }
          }
        }
      } catch (error) {
        if (!_isProviderFailure(error)) rethrow;
        // Any candidates already returned by MAL still require user choice.
        // Only a completely empty/unavailable primary search uses TMDB.
      }
      if (candidates.isNotEmpty) break;
    }
    return candidates;
  }

  @override
  Future<VideoMetadataWork?> fetchWorkForLookup(VideoMetadataLookup lookup) {
    final VideoMetadataProvider? provider =
        _manualSearchProvider(lookup.provider);
    if (provider == null) return Future<VideoMetadataWork?>.value(null);
    return provider.fetchWork(lookup);
  }

  @override
  Future<List<VideoMetadataEpisodeGroupSummary>> listEpisodeGroups(
    VideoMetadataLookup lookup,
  ) {
    final VideoMetadataProvider? provider =
        _manualSearchProvider(lookup.provider);
    if (provider == null || provider is! VideoMetadataEpisodeGroupProvider) {
      return Future<List<VideoMetadataEpisodeGroupSummary>>.value(
        const <VideoMetadataEpisodeGroupSummary>[],
      );
    }
    return (provider as VideoMetadataEpisodeGroupProvider)
        .listEpisodeGroups(lookup);
  }

  @override
  Future<SourceScrapeReport> rescrapeWorkWithLookup({
    required SourceLibraryRow source,
    required String workTitle,
    String? workStableKey,
    required VideoMetadataLookup lookup,
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
  }) async {
    final VideoSourceScrapeWork work =
        await _plannedWork(source, workTitle, workStableKey: workStableKey);
    // 手动指定与下载导入共用身份受控刮削入口，保留用户选定的来源和作品 ID。
    return scrapeSource(
      source,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
      plannedWorks: <VideoSourceScrapeWork>[work],
      confirmedLookups: <String, VideoMetadataLookup>{work.stableKey: lookup},
      runScope: 'work',
    );
  }

  Future<VideoSourceScrapeWork> _plannedWork(
    SourceLibraryRow source,
    String workTitle, {
    String? workStableKey,
  }) async =>
      await _plannedWorkOrNull(source, workTitle,
          workStableKey: workStableKey) ??
      (throw VideoSourceScrapeWorkNotFound(workTitle));

  Future<VideoSourceScrapeWork?> _plannedWorkOrNull(
    SourceLibraryRow source,
    String workTitle, {
    String? workStableKey,
  }) async {
    final List<VideoSourceScrapeWork> works =
        await VideoSourceWorkPlanner(database).plan(source);
    final List<VideoSourceScrapeWork> matching = works
        .where(
          (VideoSourceScrapeWork work) => workStableKey != null
              ? work.stableKey == workStableKey
              : work.title == workTitle,
        )
        .toList();
    // 历史记录只有标题，遇同名作品必须拒绝绑定，不能默选第一个。
    if (matching.length > 1) {
      throw VideoSourceScrapeWorkAmbiguous(workTitle);
    }
    return matching.singleOrNull;
  }

  Future<VideoMetadataProviderKind> _sourceProvider(
    SourceLibraryRow source,
  ) async =>
      _EffectiveSourceSettings.from(
        await database.getVideoSourceScrapeSettings(source.id),
        config,
        allowProtectedOverwrite: false,
        primaryProvider: primaryProvider,
      ).provider;

  /// 某来源的询问链：主源 + 兜底源（MAL ↔ TMDB 互为兜底；AniDB 等单源无兜底）。
  static List<VideoMetadataProviderKind> _providerChain(
    VideoMetadataProviderKind selected,
  ) =>
      <VideoMetadataProviderKind>[
        selected,
        if (videoMetadataFallbackProvider(selected)
            case final VideoMetadataProviderKind fallback)
          fallback,
      ];

  /// 是否为双源策略（有兜底源）。旧代码到处写 `selected == mal` 表达的其实就是
  /// 这个意思；换成 TMDB 主源后语义一样成立。
  static bool _isTwoSourcePolicy(VideoMetadataProviderKind selected) =>
      videoMetadataFallbackProvider(selected) != null;

  /// 取一个已配置的来源，手动搜索由上层按主源 → 兜底源顺序调用。
  VideoMetadataProvider? _manualSearchProvider(
    VideoMetadataProviderKind selected,
  ) {
    final VideoMetadataProvider? primary = registry.provider(selected);
    if (primary != null && primary.isAvailable) return primary;
    return null;
  }

  /// 剧集/电影形态由来源计划里的真实成员决定，与 [_resolveWork] 同一判据。
  VideoMetadataMediaKind _manualMediaKind(VideoSourceScrapeWork work) {
    final VideoNameInfo parsed =
        parseVideoFilename(p.basename(work.members.first.videoPath));
    return work.isEpisodic || parsed.episode != null
        ? VideoMetadataMediaKind.tv
        : VideoMetadataMediaKind.movie;
  }

  @override
  Future<SourceScrapeReport> scrapeSource(
    SourceLibraryRow source, {
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
    VideoSourceScrapeConfirmationCallback? onConfirmation,
    VideoSourceScrapeBatchContext? batchContext,
    List<VideoSourceScrapeWork>? plannedWorks,
    Map<String, VideoMetadataLookup> confirmedLookups =
        const <String, VideoMetadataLookup>{},
    String runScope = 'source',
  }) {
    final VideoScrapeOperationLease? lease =
        VideoScrapeOperationGate.tryEnterOperation();
    if (lease == null) {
      return Future<SourceScrapeReport>.error(
        StateError('视频刮削资料正在清理'),
      );
    }
    return _scrapeSourceUnlocked(
      source,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
      onConfirmation: onConfirmation,
      batchContext: batchContext,
      plannedWorks: plannedWorks,
      confirmedLookups: confirmedLookups,
      runScope: runScope,
    ).whenComplete(lease.release);
  }

  Future<SourceScrapeReport> _scrapeSourceUnlocked(
    SourceLibraryRow source, {
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
    VideoSourceScrapeConfirmationCallback? onConfirmation,
    VideoSourceScrapeBatchContext? batchContext,
    List<VideoSourceScrapeWork>? plannedWorks,
    Map<String, VideoMetadataLookup> confirmedLookups =
        const <String, VideoMetadataLookup>{},
    String runScope = 'source',
  }) async {
    // 识别结果只在本次用户批次内复用。全部来源时混来源合集共享同一份作品资料，
    // 但每个来源仍独立执行安全 sidecar 落盘；下次用户重刮会创建新 context。
    final VideoSourceScrapeBatchContext effectiveBatch =
        batchContext ?? VideoSourceScrapeBatchContext();
    if (source.mediaKind != 'video' || source.transport != 'local') {
      return SourceScrapeReport(
        sourceIds: <int>[source.id],
        warnings: <SourceScrapeIssue>[
          SourceScrapeIssue(
            workTitle: source.label,
            message: '只允许刮削已登记的本地视频来源',
          ),
        ],
      );
    }
    final VideoSourceScrapeSettingRow? storedSettings =
        await database.getVideoSourceScrapeSettings(source.id);
    final _EffectiveSourceSettings settings = _EffectiveSourceSettings.from(
      storedSettings,
      config,
      allowProtectedOverwrite: cancellationToken.allowProtectedOverwrite,
      primaryProvider: primaryProvider,
    );
    if (!settings.enabled) {
      return SourceScrapeReport(sourceIds: <int>[source.id]);
    }

    // 来源级资料语言与全局不同 → 这一趟用一套自己的 provider（TMDB 的
    // `language` 只能在构造期给），finally 里关掉。注入进来的 registry 不属于
    // 协调器，永远只读不关（见 [_ownsRegistry]）——这里关的是本方法自己建的那套。
    if (settings.locale != config.locale) {
      _scopedLocale = settings.locale;
      _scopedRegistry = _localeRegistryFactory(settings.locale);
    }

    final int startedAt = DateTime.now().millisecondsSinceEpoch;
    final int runId = await database.insertVideoSourceScrapeRun(
      VideoSourceScrapeRunsCompanion.insert(
        sourceId: Value<int?>(source.id),
        scope: runScope,
        status: 'running',
        provider: Value<String?>(settings.provider.name),
        phase: const Value<String?>('planning'),
        startedAt: startedAt,
        updatedAt: startedAt,
      ),
    );
    _activeRunId = runId;

    final List<SourceScrapeIssue> warnings = <SourceScrapeIssue>[];
    final List<SourceScrapeIssue> errors = <SourceScrapeIssue>[];
    int succeeded = 0;
    int failed = 0;
    int pending = 0;
    int nfoWritten = 0;
    int imagesWritten = 0;
    int protectedArtifacts = 0;
    int unchangedArtifacts = 0;
    List<VideoSourceScrapeWork> works = const <VideoSourceScrapeWork>[];
    // 本趟的已确认身份：调用方给的 + 途中按 AniDB 作品拆出来的电影子单元。
    final Map<String, VideoMetadataLookup> lookups =
        <String, VideoMetadataLookup>{...confirmedLookups};
    try {
      cancellationToken.throwIfCancelled();
      works =
          plannedWorks ?? await VideoSourceWorkPlanner(database).plan(source);
      final List<String> knownSourcePaths = (await database.allVideoBooks())
          .where((VideoBookRow row) => row.sourceId == source.id)
          .map((VideoBookRow row) => row.videoPath)
          .toList(growable: false);
      await _publish(
        runId,
        onProgress,
        VideoSourceScrapeProgress(
          phase: VideoSourceScrapePhase.planning,
          sourceId: source.id,
          sourceLabel: source.label,
          total: works.length,
        ),
        totalWorks: works.length,
      );

      // 批级快速失败门：询问链上一家都不可用才整批停。已确认 / 已落库的身份
      // 来自任一可选主源都会按那家直取（`acceptsCanonical`），所以链外的可选
      // 主源可用时也放行，让每条作品自己按 resolver 的结构化状态结账。
      final bool hasProvider = <VideoMetadataProviderKind>{
        ..._providerChain(settings.provider),
        ...kSelectableVideoMetadataProviders,
      }.any((VideoMetadataProviderKind kind) =>
          _registry.provider(kind)?.isAvailable ?? false);
      if (!hasProvider && works.isNotEmpty) {
        failed = works.length;
        errors.add(SourceScrapeIssue(
          workTitle: source.label,
          message: describeVideoScrapeFailure(
            VideoMetadataResolutionStatus.providerUnavailable,
            null,
          ),
        ));
      }

      // AniDB 明确下发 banned 后整批停手。封禁按客户端 IP 记在服务端、是 endpoint
      // 级的，继续按 3s 一条往下走：每条都注定失败，且每条都在延长封禁。provider
      // 侧已经闩住不再发请求（见 AniDbVideoMetadataProvider.isBanned），这里负责把
      // 「剩下的没做」如实结账成一条可操作说明，而不是让用户对着 N 条一模一样的分
      // 集抓取失败去猜发生了什么。
      final AniDbVideoMetadataProvider? anidb =
          switch (_registry.provider(VideoMetadataProviderKind.anidb)) {
        final AniDbVideoMetadataProvider provider => provider,
        _ => null,
      };
      int startedWorks = 0;

      if (hasProvider && anidb?.isBanned != true) {
        // Shoko：文件身份决定作品归属。散在合集外、哈希指向同一部剧的单文件
        // 单元先合成一个剧集单元再进主循环（BUG-2624）。
        final List<VideoSourceScrapeWork> merged =
            await _mergeStandaloneByAnidbWork(
          works,
          source,
          lookups: lookups,
          warnings: warnings,
          token: cancellationToken,
          onHashProgress: (String path, int bytes, int totalBytes) =>
              onProgress(
            VideoSourceScrapeProgress(
              phase: VideoSourceScrapePhase.recognizing,
              sourceId: source.id,
              sourceLabel: source.label,
              currentWorkTitle: p.basename(path),
              current: 0,
              total: works.length,
              message: 'AniDB ED2K ${p.basename(path)}：$bytes / $totalBytes 字节',
            ),
          ),
          primaryProvider: settings.provider,
        );
        if (!identical(merged, works)) {
          works = merged;
          await _publish(
            runId,
            onProgress,
            VideoSourceScrapeProgress(
              phase: VideoSourceScrapePhase.planning,
              sourceId: source.id,
              sourceLabel: source.label,
              total: works.length,
            ),
            totalWorks: works.length,
          );
        }
      }

      for (int index = 0;
          hasProvider && anidb?.isBanned != true && index < works.length;
          index++) {
        startedWorks++;
        cancellationToken.throwIfCancelled();
        final VideoSourceScrapeWork localWork = works[index];
        await _publish(
          runId,
          onProgress,
          VideoSourceScrapeProgress(
            phase: VideoSourceScrapePhase.recognizing,
            sourceId: source.id,
            sourceLabel: source.label,
            currentWorkTitle: localWork.title,
            current: index,
            total: works.length,
          ),
          currentWorkTitle: localWork.title,
          processedWorks: index,
          succeededWorks: succeeded,
          failedWorks: failed,
          pendingConfirmations: pending,
        );
        try {
          final _ResolvedWork resolved = await _resolveWork(
            localWork,
            settings.provider,
            warnings,
            confirmedLookup: lookups[localWork.stableKey],
            cancellationToken: cancellationToken,
            onHashProgress: (String path, int bytes, int totalBytes) =>
                onProgress(
              VideoSourceScrapeProgress(
                phase: VideoSourceScrapePhase.recognizing,
                sourceId: source.id,
                sourceLabel: source.label,
                currentWorkTitle: localWork.title,
                current: index,
                total: works.length,
                message:
                    'AniDB ED2K ${p.basename(path)}：$bytes / $totalBytes 字节',
              ),
            ),
            resolvedWorkCache: effectiveBatch.resolvedWorks,
            authoritativeSeasonEpisodesCache:
                effectiveBatch.authoritativeSeasonEpisodes,
            source: source,
            onConfirmation: onConfirmation,
          );
          if (resolved.pending) {
            // Shoko：文件身份决定作品归属——一个目录里几部剧场版各自是各自的
            // AniDB 作品，就拆成几部电影各自刮（`CrossRef_AniDB_TMDB_Movie`），
            // 不再作为一个「待拆分合集」悬着。子单元插在本单元之后按序处理，
            // 身份由 Fribb 映射给出；合集级残留作品行一并清掉。
            final List<_SplitWork> split = resolved.splitInto;
            if (split.isNotEmpty) {
              works = <VideoSourceScrapeWork>[
                ...works.take(index + 1),
                for (final _SplitWork piece in split) piece.work,
                ...works.skip(index + 1),
              ];
              for (final _SplitWork piece in split) {
                if (piece.lookup case final VideoMetadataLookup lookup) {
                  lookups[piece.work.stableKey] = lookup;
                }
              }
              // 总数变了：run 行与进度条按新的作品数走。
              await _publish(
                runId,
                onProgress,
                VideoSourceScrapeProgress(
                  phase: VideoSourceScrapePhase.recognizing,
                  sourceId: source.id,
                  sourceLabel: source.label,
                  currentWorkTitle: localWork.title,
                  current: index,
                  total: works.length,
                ),
                totalWorks: works.length,
              );
              warnings.add(SourceScrapeIssue(
                workTitle: localWork.title,
                message: resolved.reason ??
                    '成员分属不同 AniDB 作品，已拆成 ${split.length} 个作品各自刮削。',
              ));
              continue;
            }
            pending++;
            warnings.add(SourceScrapeIssue(
              workTitle: localWork.title,
              message: describeVideoScrapeFailure(
                VideoMetadataResolutionStatus.ambiguous,
                resolved.reason,
              ),
            ));
            continue;
          }
          final VideoMetadataWork? metadata = resolved.metadata;
          if (metadata == null) {
            failed++;
            errors.add(SourceScrapeIssue(
              workTitle: localWork.title,
              message: describeVideoScrapeFailure(
                resolved.status,
                resolved.reason,
              ),
            ));
            continue;
          }

          cancellationToken.throwIfCancelled();
          await _publish(
            runId,
            onProgress,
            VideoSourceScrapeProgress(
              phase: VideoSourceScrapePhase.applying,
              sourceId: source.id,
              sourceLabel: source.label,
              currentWorkTitle: localWork.title,
              current: index,
              total: works.length,
            ),
          );
          final PersistedVideoMetadata persisted = await _store.apply(
            localWork,
            metadata,
            seasonEpisodesAuthoritative: resolved.seasonEpisodesAuthoritative,
            episodeOverrides: resolved.episodeOverrides,
            anidbEpisodeXrefs: resolved.anidbEpisodeXrefs,
            additionalEpisodeBindings: resolved.anidbAdditionalBindings,
            userVerifiedBooks: resolved.userVerifiedBooks,
          );

          cancellationToken.throwIfCancelled();
          await _publish(
            runId,
            onProgress,
            VideoSourceScrapeProgress(
              phase: VideoSourceScrapePhase.writingSidecars,
              sourceId: source.id,
              sourceLabel: source.label,
              currentWorkTitle: localWork.title,
              current: index,
              total: works.length,
            ),
          );
          final _SidecarOutcome sidecars = await _writeSidecars(
            source: source,
            runId: runId,
            localWork: localWork,
            metadata: metadata,
            persisted: persisted,
            knownSourcePaths: knownSourcePaths,
            settings: settings,
            cancellationToken: cancellationToken,
            episodeOverrides: resolved.episodeOverrides,
          );
          nfoWritten += sidecars.nfoWritten;
          imagesWritten += sidecars.imagesWritten;
          protectedArtifacts += sidecars.protectedArtifacts;
          unchangedArtifacts += sidecars.unchangedArtifacts;
          warnings.addAll(sidecars.warnings);
          errors.addAll(sidecars.errors);
          await _downloadStaffImages(
            localWork, metadata, warnings, cancellationToken);
          succeeded++;
          // 播「这个作品刮完了」。放在 succeeded++ 之后：只有真正刮成功的作品
          // 才值得去补字幕，失败的连身份都不可信。
          final Future<void> Function(VideoScrapedWorkNotice)? notify =
              onWorkScraped;
          if (notify != null) {
            try {
              await notify(
                VideoScrapedWorkNotice(work: localWork, metadata: metadata),
              );
            } on VideoSourceScrapeCancelled {
              rethrow;
            } catch (error) {
              // 补字幕失败绝不影响刮削结论——它是刮削的下游增值，不是前置条件。
              warnings.add(SourceScrapeIssue(
                workTitle: localWork.title,
                message: '字幕补齐失败：$error',
              ));
            }
          }
        } on VideoSourceScrapeCancelled {
          rethrow;
        } catch (error) {
          failed++;
          errors.add(SourceScrapeIssue(
            workTitle: localWork.title,
            message: error.toString(),
          ));
        } finally {
          await _updateRunCounts(
            runId,
            processedWorks: index + 1,
            succeededWorks: succeeded,
            failedWorks: failed,
            pendingConfirmations: pending,
          );
        }
      }

      final Duration? banRemaining = anidb?.banRemaining;
      final int skippedByBan = works.length - startedWorks;
      if (banRemaining != null && hasProvider && skippedByBan > 0) {
        failed += skippedByBan;
        errors.add(SourceScrapeIssue(
          workTitle: source.label,
          message: 'AniDB 已封禁本客户端，本轮剩余 $skippedByBan 个作品全部跳过'
              '（约 ${banRemaining.inHours + 1} 小时后自动恢复）。'
              '封禁期间继续请求只会延长封禁。',
        ));
      }

      final SourceScrapeReport report = SourceScrapeReport(
        sourceIds: <int>[source.id],
        totalWorks: works.length,
        succeededWorks: succeeded,
        failedWorks: failed,
        pendingConfirmations: pending,
        nfoWritten: nfoWritten,
        imagesWritten: imagesWritten,
        protectedArtifacts: protectedArtifacts,
        unchangedArtifacts: unchangedArtifacts,
        warnings: List<SourceScrapeIssue>.unmodifiable(warnings),
        errors: List<SourceScrapeIssue>.unmodifiable(errors),
      );
      cancellationToken.throwIfCancelled();
      await _finishRun(runId, status: 'completed', report: report);
      return report;
    } on VideoSourceScrapeCancelled {
      final SourceScrapeReport report = SourceScrapeReport(
        sourceIds: <int>[source.id],
        totalWorks: works.length,
        succeededWorks: succeeded,
        failedWorks: failed,
        pendingConfirmations: pending,
        nfoWritten: nfoWritten,
        imagesWritten: imagesWritten,
        protectedArtifacts: protectedArtifacts,
        unchangedArtifacts: unchangedArtifacts,
        warnings: warnings,
        errors: errors,
        cancelled: true,
      );
      final String status =
          _interruptedRunIds.contains(runId) ? 'interrupted' : 'cancelled';
      await _finishRun(runId, status: status, report: report);
      rethrow;
    } catch (error) {
      final SourceScrapeReport report = SourceScrapeReport(
        sourceIds: <int>[source.id],
        totalWorks: works.length,
        succeededWorks: succeeded,
        failedWorks: failed + 1,
        pendingConfirmations: pending,
        nfoWritten: nfoWritten,
        imagesWritten: imagesWritten,
        protectedArtifacts: protectedArtifacts,
        unchangedArtifacts: unchangedArtifacts,
        warnings: warnings,
        errors: <SourceScrapeIssue>[
          ...errors,
          SourceScrapeIssue(workTitle: source.label, message: error.toString()),
        ],
      );
      await _finishRun(
        runId,
        status: 'failed',
        report: report,
        lastError: error.toString(),
      );
      rethrow;
    } finally {
      if (_activeRunId == runId) _activeRunId = null;
      _interruptedRunIds.remove(runId);
      _scopedRegistry?.close();
      _scopedRegistry = null;
      _scopedLocale = null;
    }
  }

  Future<_ResolvedWork> _resolveWork(
    VideoSourceScrapeWork localWork,
    VideoMetadataProviderKind selectedProvider,
    List<SourceScrapeIssue> warnings, {
    VideoMetadataLookup? confirmedLookup,
    required VideoSourceScrapeCancellationToken cancellationToken,
    required void Function(String, int, int) onHashProgress,
    required Map<String, VideoMetadataWork> resolvedWorkCache,
    required Map<String, bool> authoritativeSeasonEpisodesCache,
    required SourceLibraryRow source,
    required VideoSourceScrapeConfirmationCallback? onConfirmation,
  }) async {
    final String cacheKey = localWork.stableKey;
    final VideoMetadataWork? cached = resolvedWorkCache[cacheKey];
    if (cached != null && confirmedLookup == null) {
      return _ResolvedWork(
        metadata: cached,
        seasonEpisodesAuthoritative:
            authoritativeSeasonEpisodesCache[cacheKey] ?? false,
        episodeOverrides:
            _episodeOverridesCache[cacheKey] ?? const <String, (int, int)>{},
        anidbEpisodeXrefs:
            _anidbXrefCache[cacheKey] ?? const <String, AnidbEpisodeXref>{},
        anidbAdditionalBindings: _anidbAdditionalCache[cacheKey] ??
            const <String, Map<(int, int), AnidbEpisodeXref>>{},
        userVerifiedBooks: _userVerifiedCache[cacheKey] ?? const <String>{},
      );
    }

    final VideoNameInfo parsed =
        parseVideoFilename(p.basename(localWork.members.first.videoPath));
    final int? seasonNumber = _parsedSeason(localWork, parsed);
    // 单文件单元带着已确认身份时，形态跟身份走（`Movie 01.mkv` 这种带序号的
    // 剧场版文件名会被误判成剧集；按 AniDB 作品拆出来的电影子单元就是这样）。
    VideoMetadataMediaKind kind = !localWork.isEpisodic && confirmedLookup != null
        ? confirmedLookup.mediaKind
        : localWork.isEpisodic || parsed.episode != null
            ? VideoMetadataMediaKind.tv
            : VideoMetadataMediaKind.movie;
    VideoMetadataWork? nfo = await VideoNfoReader(
      generatedArtifactChecker:
          DatabaseSidecarGeneratedArtifactChecker(database),
    ).readForPaths(
      sourceRoot: source.rootPath,
      fallbackTitle: localWork.title,
      videoPaths: <String>[
        for (final VideoBookRow member in localWork.members) member.videoPath,
      ],
    );
    final List<VideoMetadataLookup> storedLookups =
        await _store.lookupsForWork(localWork);
    final List<VideoMetadataProviderKind> chain =
        _providerChain(selectedProvider);
    final bool twoSourcePolicy = _isTwoSourcePolicy(selectedProvider);
    // 已确认 / 已落库 / NFO 默认身份只要来自**仍可选的生产主源**（AniDB / MAL /
    // TMDB）就是有效的规范绑定，不因用户切换默认主源而被静默换源重识别（对齐
    // 2026-09-20 默认从 MAL 切到 AniDB：存量 MAL 作品保持身份，由仍注册的 MAL
    // provider 续刮）。只有退役 provider（bangumi / douban / anilist …）才算旧身份。
    bool acceptsCanonical(VideoMetadataLookup lookup) =>
        chain.contains(lookup.provider) ||
        kSelectableVideoMetadataProviders.contains(lookup.provider);
    final VideoMetadataLookup? confirmedCanonical =
        confirmedLookup != null && acceptsCanonical(confirmedLookup)
            ? confirmedLookup
            : null;
    // Only an identity flagged primary counts as "the" primary. A retired
    // primary's TMDB cross-reference must not silently become a new canonical
    // binding; a work that never had a primary (NFO-indexed cross references
    // only) has nothing retired and keeps its hints.
    final VideoMetadataLookup? storedPrimary =
        await _store.primaryLookupForWork(localWork);
    final bool retiredStoredIdentity = twoSourcePolicy &&
        storedPrimary != null &&
        !acceptsCanonical(storedPrimary);
    final VideoMetadataLookup? storedCanonical = twoSourcePolicy
        ? (storedPrimary != null && acceptsCanonical(storedPrimary)
            ? storedPrimary
            : null)
        : storedLookups.where(acceptsCanonical).firstOrNull;
    final List<VideoMetadataLookup> nfoLookups = _lookupsForNfo(nfo);
    final Set<String> defaultNfoSources = <String>{
      for (final VideoMetadataId id in nfo?.ids ?? <VideoMetadataId>[])
        if (id.isDefault) id.type,
    };
    final VideoMetadataLookup? nfoPrimary = nfoLookups
        .where((VideoMetadataLookup lookup) =>
            defaultNfoSources.contains(lookup.provider.name))
        .firstOrNull;
    final VideoMetadataLookup? nfoIdentityOwner =
        nfoPrimary ?? nfoLookups.firstOrNull;
    final bool retiredNfoIdentity = twoSourcePolicy &&
        nfoIdentityOwner != null &&
        !acceptsCanonical(nfoIdentityOwner);
    // TMDB 的 /movie 与 /tv 是两个 id 空间：`<movie>` NFO 里的 TMDB id 不能成为
    // 剧集单元的规范身份（反之亦然），否则一份放错的 NFO 会把整个合集刮成电影。
    // MAL / AniDB 同一 id 空间不分形态，不受此限（与 `_tmdbSupplement` 的
    // incompatibleHint、`mergeNfoAuthority` 的 TMDB 形态门同一判据）。
    bool sameTmdbNamespace(VideoMetadataLookup lookup) =>
        lookup.provider != VideoMetadataProviderKind.tmdb ||
        lookup.mediaKind == kind;
    final VideoMetadataLookup? nfoCanonical = twoSourcePolicy
        ? (nfoPrimary != null &&
                acceptsCanonical(nfoPrimary) &&
                sameTmdbNamespace(nfoPrimary)
            ? nfoPrimary
            : null)
        : nfoLookups
            .where(acceptsCanonical)
            .where(sameTmdbNamespace)
            .firstOrNull;
    final VideoMetadataLookup? storedSameSource = confirmedCanonical == null
        ? null
        : _lookupForProvider(storedLookups, confirmedCanonical.provider);
    final bool changedIdentity = confirmedCanonical != null &&
        storedLookups.isNotEmpty &&
        (storedSameSource == null ||
            !_sameLookup(confirmedCanonical, storedSameSource));
    final VideoMetadataLookup? nfoSameSource = confirmedCanonical == null
        ? null
        : _lookupForProvider(nfoLookups, confirmedCanonical.provider);
    final bool conflictingNfo = nfo != null &&
        confirmedCanonical != null &&
        (nfoSameSource != null
            ? !_sameLookup(confirmedCanonical, nfoSameSource)
            : changedIdentity ||
                nfoLookups.any((VideoMetadataLookup lookup) =>
                    lookup.provider == VideoMetadataProviderKind.mal ||
                    lookup.provider == VideoMetadataProviderKind.tmdb ||
                    lookup.provider == VideoMetadataProviderKind.anidb));
    if (conflictingNfo) {
      warnings.add(SourceScrapeIssue(
          workTitle: localWork.title,
          message:
              '本地 NFO 与本次确认的 ${confirmedCanonical.provider.name.toUpperCase()} 作品身份不一致，未应用其中的资料；原文件仍按已有写入保护策略保留。'));
      nfo = null;
    }
    if (retiredNfoIdentity && nfo != null) {
      warnings.add(SourceScrapeIssue(
          workTitle: localWork.title,
          message:
              '本地 NFO 的主身份来自旧资料源，需按当前主源重新识别；未沿用旧跨源关联或展示资料，原文件仍按已有写入保护策略保留。'));
      nfo = null;
    }
    final List<VideoMetadataLookup> reusableLookups =
        changedIdentity || retiredStoredIdentity
            ? const <VideoMetadataLookup>[]
            : storedLookups;
    // 识别词（设计稿 C）：用户词表先把字幕组/发布组等噪声块从标题候选里删掉或
    // 改写。改写结果排在原候选之前，原候选保留在后——规则写错时至少还能按原
    // 标题搜到东西，而不是整条识别归零。
    final List<String> candidates = applyScrapeIdentifierWordsToCandidates(
      <String>[
        if (nfo != null) nfo.title,
        ..._titleCandidates(localWork, parsed),
      ],
      config.identifierWords,
    );
    final List<VideoMetadataLookup> identityHints = <VideoMetadataLookup>[
      if (confirmedLookup != null) confirmedLookup,
      ...reusableLookups,
      ..._lookupsForNfo(nfo),
    ];
    final VideoMetadataLookup? canonicalLookup = confirmedCanonical ??
        storedCanonical ??
        (conflictingNfo || retiredNfoIdentity ? null : nfoCanonical);
    VideoMetadataLookup? tmdbLookupHint =
        _lookupForProvider(identityHints, VideoMetadataProviderKind.tmdb);
    final List<String> pathHints = <String>[
      for (final VideoBookRow member in localWork.members) member.videoPath,
    ];
    final bool hasExplicitId =
        parseExplicitVideoMetadataIds(pathHints, fallbackMediaKind: kind)
            .isNotEmpty;
    // 对齐 Shoko：哈希是**文件级第一步**，作品有没有身份都先认文件——新落进
    // 已识别作品的文件照样哈希、落 `anidb_file_identities`（已认过的文件由持久
    // 层直接命中，不重算不重问）。作品级身份的优先级不变：已确认 / 已落库 /
    // NFO / 路径显式 id 在前，哈希只在它们都没有时决定作品是谁（BUG-2586）。
    final _HashWorkEvidence hashEvidence = await _identifyWork(
        localWork, warnings, cancellationToken, onHashProgress);
    cancellationToken.throwIfCancelled();
    final bool hashDecidesIdentity = canonicalLookup == null && !hasExplicitId;
    // 成员哈希分属多部作品 → 拆分**只在哈希决定身份时**。已确认 / 已落库 / NFO /
    // 路径显式 id 在前（上面的注释就是这条优先级），手动指定的身份不得被哈希
    // 静默换掉——更不能把用户的合集删了拆成 N 个（物语系列 / Fate / 多 cour 番
    // 天然多 aid，用户手动指定一个作品正是想让它们留在一起）。这种情况下保留
    // 身份、不按哈希做集级链接，下面按「哈希与已确认身份打架」报一条说明。
    if (hashEvidence.conflicting && hashDecidesIdentity) {
      final List<_SplitWork> split =
          await _splitByAnidbWork(localWork, hashEvidence, source,
              primaryProvider: selectedProvider);
      if (split.isNotEmpty) {
        final int movies = split
            .where((_SplitWork s) => s.kind == VideoMetadataMediaKind.movie)
            .length;
        final int shows = split.length - movies;
        return _ResolvedWork(
            pending: true,
            status: VideoMetadataResolutionStatus.ambiguous,
            reason:
                'AniDB 文件哈希识别出 ${split.map((_SplitWork s) => s.animeId).toSet().length} 部不同作品（${split.map((_SplitWork s) => 'aid ${s.animeId}').toSet().join('、')}），'
                '已按 Shoko 方式拆开各自刮削：${movies > 0 ? '$movies 部电影' : ''}${movies > 0 && shows > 0 ? '、' : ''}${shows > 0 ? '$shows 个剧集合集' : ''}。',
            splitInto: split);
      }
      return const _ResolvedWork(
          pending: true,
          status: VideoMetadataResolutionStatus.ambiguous,
          reason: 'AniDB 文件哈希识别结果属于不同作品；请拆分合集或手动确认作品。');
    }
    // Shoko 的作品形态由 AniDB 动画类型决定：单文件单元、哈希决定身份时，`Movie`
    // 就是电影、其它就是剧集——文件名有没有序号不再作数。
    if (hashDecidesIdentity && !localWork.isEpisodic) {
      final AnidbFileIdentity? identity =
          hashEvidence.identities[localWork.members.single.bookUid];
      if (identity != null && identity.animeType.isNotEmpty) {
        kind = identity.isMovieType
            ? VideoMetadataMediaKind.movie
            : VideoMetadataMediaKind.tv;
      }
    }
    // 主源是 AniDB（Shoko 形态）时哈希给出的 aid 直接就是作品身份，不经 Fribb；
    // 主源是 MAL 时才有「AniDB → MAL 一对多」这层。
    final bool anidbPrimary =
        selectedProvider == VideoMetadataProviderKind.anidb;
    // 跨站映射一对多（Fribb 把一个 AniDB 作品映到多个 MAL 条目）：AniDB 身份本身
    // 已经成立，只是 MAL 那边要选——把各候选拉出来交 AI / 人工，不再让作品悬空。
    final bool hashMappingAmbiguous = !anidbPrimary &&
        hashDecidesIdentity &&
        hashEvidence.animeId != null &&
        hashEvidence.mappedMalIds.length > 1;
    final int? canonicalMalId =
        canonicalLookup?.provider == VideoMetadataProviderKind.mal
            ? int.tryParse(canonicalLookup!.externalId)
            : null;
    final int? canonicalAnidbId =
        canonicalLookup?.provider == VideoMetadataProviderKind.anidb
            ? int.tryParse(canonicalLookup!.externalId)
            : null;
    // 哈希与已确认身份打架：文件确定属于 AniDB X，而当前已确认的是别的 AniDB
    // 作品 / X 映到的 MAL 里没有当前这个 MAL id。保留已确认身份（手动指定不得
    // 静默换源），只报出来。
    final bool hashContradictsCanonical = !hashDecidesIdentity &&
        (hashEvidence.conflicting ||
            (hashEvidence.animeId != null &&
                ((canonicalAnidbId != null &&
                        canonicalAnidbId != hashEvidence.animeId) ||
                    (canonicalMalId != null &&
                        hashEvidence.mappedMalIds.isNotEmpty &&
                        !hashEvidence.mappedMalIds.contains(canonicalMalId)))));
    if (hashContradictsCanonical) {
      final String current = canonicalAnidbId != null
          ? 'AniDB $canonicalAnidbId'
          : canonicalMalId != null
              ? 'MAL $canonicalMalId'
              : canonicalLookup != null
                  ? '${canonicalLookup.provider.name} ${canonicalLookup.externalId}'
                  : '路径显式 id';
      warnings.add(SourceScrapeIssue(
          workTitle: localWork.title,
          message: hashEvidence.conflicting
              ? '文件哈希分属多部 AniDB 作品（${hashEvidence.identities.values.map((AnidbFileIdentity i) => i.animeId).whereType<int>().toSet().map((int aid) => 'aid $aid').join('、')}），'
                  '而作品已有身份 $current；已保留该身份、未拆分，本轮不按文件哈希做集级链接。'
              : '文件哈希指向 AniDB ${hashEvidence.animeId}（anime-lists 映射 MAL ${hashEvidence.mappedMalIds.join('/')}），'
                  '与当前已确认身份 $current 不一致；已保留当前身份，未改写。'));
    }
    final VideoMetadataLookup? hashLookup = !hashDecidesIdentity
        ? null
        : anidbPrimary && hashEvidence.animeId != null
            ? VideoMetadataLookup(
                provider: VideoMetadataProviderKind.anidb,
                externalId: '${hashEvidence.animeId}',
                mediaKind: kind,
              )
            : hashEvidence.malId == null
                ? null
                : VideoMetadataLookup(
                    provider: VideoMetadataProviderKind.mal,
                    externalId: '${hashEvidence.malId}',
                    mediaKind: kind,
                  );
    final List<String> searchTitles = <String>[
      if (hashDecidesIdentity && hashEvidence.animeId != null)
        ...hashEvidence.titles
      else
        ...candidates,
    ];
    // 离线标题索引阶段（A2）：没有任何已知身份时，先拿标题去 AniDB 标题包做
    // 唯一精确命中，再经 Fribb 换成链上两家的 id。命中后按 id 直拉，不发搜索。
    final AnimeOfflineIdentity? offline =
        hashDecidesIdentity && hashLookup == null && !hashMappingAmbiguous
            ? await _identifyOffline(searchTitles, kind, warnings, localWork,
                primaryProvider: selectedProvider)
            : null;
    final List<VideoMetadataLookup> offlineLookups = <VideoMetadataLookup>[
      if (offline != null)
        for (final VideoMetadataProviderKind providerKind in chain)
          if (offline.lookupFor(providerKind, kind)
              case final VideoMetadataLookup lookup)
            lookup,
    ];
    if (offline?.tmdbId != null) {
      tmdbLookupHint ??=
          offline!.lookupFor(VideoMetadataProviderKind.tmdb, kind);
    }
    final int? searchYear = nfo?.year ?? _parsedYear(localWork);
    final int? episodeCount =
        localWork.isEpisodic ? localWork.members.length : null;
    final VideoMetadataResolver resolver =
        VideoMetadataResolver(registry: registry);
    final List<VideoMetadataWork> mappedCandidates = hashMappingAmbiguous
        ? await _fetchMappedMalCandidates(
            hashEvidence, kind, warnings, localWork)
        : const <VideoMetadataWork>[];
    VideoMetadataResolution resolution = mappedCandidates.isNotEmpty
        ? VideoMetadataResolution(
            status: VideoMetadataResolutionStatus.ambiguous,
            providerKind: VideoMetadataProviderKind.mal,
            candidates: mappedCandidates,
            reason:
                'AniDB ${hashEvidence.animeId} 在 anime-lists 映射到多个 MAL 条目（${hashEvidence.mappedMalIds.join('/')}），请确认是哪一个。',
          )
        : await resolver.resolve(VideoMetadataResolveRequest(
            selectedProvider: selectedProvider,
            fallbackProvider: videoMetadataFallbackProvider(selectedProvider),
            mediaKind: kind,
            titleCandidates: searchTitles,
            year: searchYear,
            seasonNumber: seasonNumber,
            episodeCount: episodeCount,
            confirmedLookup:
                canonicalLookup ?? hashLookup ?? offlineLookups.firstOrNull,
            identityHints: pathHints,
          ));
    if (canonicalLookup == null &&
        hashLookup == null &&
        offlineLookups.isNotEmpty) {
      // 离线身份是自动证据，不是用户锁定：主源那家 id 拉不到（Jikan 504、条目
      // 下架）就换链上另一家的 id；两家都不行才退回严格标题搜索。
      for (int index = 1;
          index < offlineLookups.length && !_isUsableResolution(resolution);
          index++) {
        final VideoMetadataLookup lookup = offlineLookups[index];
        resolution = await resolver.resolve(VideoMetadataResolveRequest(
          selectedProvider: lookup.provider,
          mediaKind: kind,
          titleCandidates: searchTitles,
          year: searchYear,
          seasonNumber: seasonNumber,
          episodeCount: episodeCount,
          confirmedLookup: lookup,
        ));
      }
      if (!_isUsableResolution(resolution)) {
        warnings.add(SourceScrapeIssue(
            workTitle: localWork.title,
            message:
                '离线标题索引已命中 AniDB ${offline!.anidbId}（${offline.matchedTitle}），但按 id 拉取资料失败（${resolution.reason}）；退回标题搜索。'));
        resolution = await resolver.resolve(VideoMetadataResolveRequest(
          selectedProvider: selectedProvider,
          fallbackProvider: videoMetadataFallbackProvider(selectedProvider),
          mediaKind: kind,
          titleCandidates: searchTitles,
          year: searchYear,
          seasonNumber: seasonNumber,
          episodeCount: episodeCount,
          identityHints: pathHints,
        ));
      }
    }
    if (canonicalLookup == null &&
        hashLookup != null &&
        resolution.status ==
            VideoMetadataResolutionStatus.providerUnavailable) {
      // A hash mapping is automatic evidence, not a user-locked MAL binding.
      // Only the unavailable mapped source may fall back to strict TMDB titles.
      resolution = await resolver.resolve(VideoMetadataResolveRequest(
        selectedProvider: VideoMetadataProviderKind.tmdb,
        mediaKind: kind,
        titleCandidates: searchTitles,
        year: nfo?.year ?? _parsedYear(localWork),
        seasonNumber: seasonNumber,
        episodeCount: localWork.isEpisodic ? localWork.members.length : null,
      ));
    }
    VideoMetadataWork? resolvedWork = resolution.work;
    VideoMetadataLookup? resolvedLookup = resolution.lookup;
    if (resolution.status == VideoMetadataResolutionStatus.ambiguous) {
      // 候选身份使用每条候选自己的来源：主备两源都只剩待确认候选时它们会被
      // 合并在一起，兜底源的结果必须保留自己的 ID 命名空间。
      final List<VideoSourceScrapeConfirmationCandidate> options =
          <VideoSourceScrapeConfirmationCandidate>[
        for (final VideoMetadataWork candidate in resolution.candidates)
          if (_lookupForCandidate(candidate, candidate.provider)
              case final VideoMetadataLookup lookup)
            VideoSourceScrapeConfirmationCandidate(
              lookup: lookup,
              work: candidate,
            ),
      ];
      if (options.isEmpty) {
        return _ResolvedWork(
          pending: true,
          reason: resolution.reason,
          status: resolution.status,
        );
      }
      // AI 消解先于人工确认：后台补刮没有确认回调，这里是它唯一能自动收敛
      // 的机会；有回调的前台批次也先问 AI，高置信直接采用，其余照旧弹给用户。
      VideoSourceScrapeConfirmationCandidate? selected =
          await _selectCandidateWithAi(
        localWork: localWork,
        localTitles: candidates,
        seasonNumber: seasonNumber,
        episodeCount: episodeCount,
        year: searchYear,
        options: options,
        warnings: warnings,
      );
      if (selected == null) {
        if (onConfirmation == null) {
          return _ResolvedWork(
            pending: true,
            reason: resolution.reason,
            status: resolution.status,
          );
        }
        selected = await onConfirmation(VideoSourceScrapeConfirmation(
          sourceId: source.id,
          sourceLabel: source.label,
          localWorkTitle: localWork.title,
          candidates: options,
        ));
      }
      if (selected == null) {
        return _ResolvedWork(
          pending: true,
          reason: resolution.reason,
          status: resolution.status,
        );
      }
      resolvedWork = selected.work;
      resolvedLookup = selected.lookup;
      if (selected.lookup.provider == VideoMetadataProviderKind.anidb &&
          selected.work.rawPayload?[
                  AniDbVideoMetadataProvider.catalogOnlyPayloadKey] ==
              true) {
        final VideoMetadataProvider? provider =
            _registry.provider(selected.lookup.provider);
        try {
          resolvedWork =
              await provider?.fetchWork(selected.lookup) ?? selected.work;
        } catch (error) {
          warnings.add(SourceScrapeIssue(
            workTitle: localWork.title,
            message: 'AniDB 手工确认项详情抓取失败，已保留标题目录摘要：$error',
          ));
        }
      }
    }
    if (resolvedWork == null || resolvedLookup == null) {
      return _ResolvedWork(
        reason: resolution.reason,
        status: resolution.status,
      );
    }

    // 身份接力：MAL 主身份 + 还没有 TMDB 身份 → 经 Fribb 换 TMDB id，补充按 id 直拉。
    tmdbLookupHint ??= await _tmdbLookupFromMapping(resolvedLookup, kind);
    final _HydratedWork primaryHydration = await _hydrateWork(
      resolvedWork,
      resolvedLookup,
      warnings,
      localWork.title,
    );
    VideoMetadataWork metadata = primaryHydration.metadata;
    if (metadata.provider == VideoMetadataProviderKind.mal &&
        hasIncompleteMalCredits(metadata)) {
      warnings.add(SourceScrapeIssue(
          workTitle: localWork.title,
          message: 'MAL 演职员资料抓取不完整，已保留作品身份和现有资料；将尝试严格匹配 TMDB 补充缺项。'));
    }
    if (metadata.episodeGroupId == null &&
        resolvedLookup.episodeGroupId != null) {
      metadata = metadata.copyWith(
        episodeGroupId: resolvedLookup.episodeGroupId,
      );
    }
    bool seasonEpisodesAuthoritative = primaryHydration.complete;
    // 识别词的集偏移先于多季扩展落地：先把本地集号纠正成该剧真实编号，多季
    // 折算才有意义（顺序反过来会拿未纠正的集号去跨季累加）。
    final Map<String, int> identifierOffsets =
        _identifierEpisodeOffsets(localWork);
    Map<String, (int, int)> episodeOverrides =
        _identifierEpisodeOverrides(localWork, identifierOffsets);
    // 多季一张卡（设计稿 B）：MAL 一个 id 只是一季。本地合集含多季（季目录 /
    // 绝对集号）时，用 Fribb 同一 TMDB 剧的季条目序列把各季映射到各自 MAL id
    // 逐季抓分集，绝对集号经 anime-relations 重定向；卡片仍是这一个合集。
    _SeasonExpansion? expansion;
    if ((metadata.provider == VideoMetadataProviderKind.mal ||
            metadata.provider == VideoMetadataProviderKind.anidb) &&
        metadata.kind == VideoMetadataMediaKind.tv &&
        resolvedLookup.provider == metadata.provider) {
      expansion = await _expandMalSeasons(
        localWork: localWork,
        primary: metadata,
        primaryLookup: resolvedLookup,
        warnings: warnings,
        episodeOffsets: identifierOffsets,
      );
      // 扩展只覆盖它真正折算过的成员；其余成员保留识别词纠正后的集号。
      episodeOverrides = <String, (int, int)>{
        ...episodeOverrides,
        ...expansion.episodeOverrides,
      };
      if (!expansion.complete) seasonEpisodesAuthoritative = false;
    }
    // Shoko 式 AniDB 集 → TMDB 集链接要用的 TMDB 剧骨架与 en-US / 原语集名：
    // 主源不是 TMDB 时来自补充源，主源就是 TMDB 时就是它自己。
    VideoMetadataWork? tmdbShow;
    Map<(int, int), List<String>>? tmdbEpisodeAliases;
    if (metadata.provider != VideoMetadataProviderKind.tmdb) {
      metadata = _preserveTmdbIdentity(metadata, tmdbLookupHint);
      metadata = remapStandaloneVideoMetadataSeason(
        metadata,
        expansion?.primarySeasonNumber ?? seasonNumber,
      );
      if (expansion != null && expansion.extraSeasons.isNotEmpty) {
        metadata = metadata.copyWith(
            seasons: <VideoMetadataSeason>[
          ...metadata.seasons,
          ...expansion.extraSeasons,
        ]..sort((VideoMetadataSeason a, VideoMetadataSeason b) =>
                a.seasonNumber.compareTo(b.seasonNumber)));
      }
      if (expansion != null && expansion.extraCredits.isNotEmpty) {
        metadata = metadata.copyWith(
          credits: mergeVideoMetadataCredits(
            metadata.credits,
            expansion.extraCredits,
          ),
        );
      }
      // Shoko：TMDB 恒为 AniDB 的补充（描述 / 图片 / 集标题源序）；MAL 主源仍按
      // 缺项才补。
      final _TmdbSupplementResult tmdb =
          metadata.provider == VideoMetadataProviderKind.mal &&
                  !_needsTmdbSupplement(metadata, seasonEpisodesAuthoritative)
              ? const _TmdbSupplementResult()
              : await _tmdbSupplement(
                  metadata,
                  changedIdentity || conflictingNfo
                      ? <String>[metadata.title, ...metadata.aliases]
                      : candidates,
                  seasonNumber,
                  warnings,
                  localWork.title,
                  lookupHint: tmdbLookupHint,
                );
      tmdbShow = tmdb.metadata;
      // 有序合并：主源标量独占、补充只填空、集合并集；简介按刮削语言感知
      // （MAL 简介恒英文，zh-CN 用户拿到 TMDB 中文简介时以后者为准）。
      metadata = supplementVideoMetadata(
        metadata,
        tmdb.metadata,
        preferredLanguage: _locale,
      );
      // MAL cour 季缺分集（播出中的作品 Jikan 常给 0 集）→ 按映射表显式的
      // 「TMDB 第 S 季从第 O+1 集起」切片补集，本地文件才挂得上分集行。
      if (expansion != null) {
        metadata = fillSeasonsFromTmdbSlices(
          metadata,
          tmdb.metadata,
          expansion.tmdbSlices,
          preferredLanguage: _locale,
        );
      }
      // Shoko `MatchAnidbToTmdbEpisodes`：映射表没给切片的季，逐集按标题 +
      // 播出日在 TMDB 里找对应——① MAL 有分集的季用 TMDB 集补空；② MAL 一集
      // 都没有的季用本地文件 AniDB 身份里的集标题核对后按 AniDB 集号落集。
      if (tmdb.metadata != null &&
          metadata.provider != VideoMetadataProviderKind.tmdb &&
          metadata.kind == VideoMetadataMediaKind.tv) {
        final Set<int> sliced = expansion?.tmdbSlices.keys.toSet() ?? <int>{};
        final Map<int, List<TmdbEpisodeMatchSource>> anidbSources =
            _anidbEpisodeSources(
                localWork, hashEvidence, episodeOverrides, metadata, sliced);
        // Shoko 比的是 en-US + 原语集名；只有真要匹配时才按季多拉两种语言。
        final Map<(int, int), List<String>> aliases =
            _needsEpisodeMatch(metadata, sliced) || anidbSources.isNotEmpty
                ? await _tmdbEpisodeAliases(
                    tmdb.metadata!, warnings, localWork.title)
                : const <(int, int), List<String>>{};
        if (aliases.isNotEmpty) tmdbEpisodeAliases = aliases;
        final TmdbEpisodeMatchOutcome enriched =
            enrichSeasonsByTmdbEpisodeMatch(
          metadata,
          tmdb.metadata,
          skipSeasons: sliced,
          preferredLanguage: _locale,
          candidateAliases: aliases,
        );
        metadata = enriched.work;
        _noteEpisodeMatches(warnings, localWork.title, enriched.ratings,
            how: '按分集标题与播出日');
        if (anidbSources.isNotEmpty) {
          final TmdbEpisodeMatchOutcome filled =
              fillEmptySeasonsFromEpisodeTitles(
                  metadata, tmdb.metadata, anidbSources,
                  candidateAliases: aliases);
          metadata = filled.work;
          // 核对通过的成员：本地 (季, 集) 改成 (季, AniDB 集号)。
          for (final VideoBookRow member in localWork.members) {
            final AnidbFileIdentity? identity =
                hashEvidence.identities[member.bookUid];
            final int? epno = _anidbEpisodeNumber(identity);
            final (int, int)? key =
                localEpisodeKeyFor(member, episodeOverrides);
            if (epno == null || key == null) continue;
            if (filled.ratings.containsKey((key.$1, epno))) {
              episodeOverrides = <String, (int, int)>{
                ...episodeOverrides,
                member.bookUid: (key.$1, epno),
              };
            }
          }
          _noteEpisodeMatches(warnings, localWork.title, filled.ratings,
              how: '按 AniDB 文件身份的集标题');
        }
      }
    }
    // 用户手动钉死的季集（Shoko `MatchRating.UserVerified`）：最高优先级，
    // AniDB 集级链接与文件名解析都不再动这些成员。
    final Map<String, VideoEpisodeBindingOverrideRow> userVerified =
        await database.getVideoEpisodeBindingOverrides(<String>[
      for (final VideoBookRow member in localWork.members) member.bookUid,
    ]);
    // Shoko 主路径（`MatchAnidbToTmdbEpisodes`）：有 AniDB 文件身份的成员，
    // 它落到哪一集由 AniDB 集（播出日 + 三语集标题）在 TMDB 剧全部季里逐集
    // 对出来决定，文件名解析的季集只是没有身份时的退路。Shoko 里文件名从不
    // 参与识别；这里同理——身份与文件名不符时按身份、记一条说明。
    // 每个有身份的成员都先落一条只带 AniDB 原生身份的交叉引用（无 TMDB 剧也
    // 呈现 AniDB 编号），链接成功的再补评级。
    Map<String, AnidbEpisodeXref> anidbXrefs = <String, AnidbEpisodeXref>{
      for (final MapEntry<String, AnidbFileIdentity> entry
          in hashEvidence.identities.entries)
        if (!hashContradictsCanonical)
          entry.key: AnidbEpisodeXref(
            episodeId: entry.value.episodeId,
            episodeNumber: entry.value.episodeNumber,
          ),
    };
    AnidbAdditionalEpisodeBindings anidbAdditional =
        const <String, Map<(int, int), AnidbEpisodeXref>>{};
    if (metadata.provider == VideoMetadataProviderKind.tmdb) {
      tmdbShow = metadata;
    }
    if (tmdbShow != null &&
        !hashContradictsCanonical &&
        metadata.kind == VideoMetadataMediaKind.tv) {
      // AniDB 主源：来源池 = anime XML 全集（Shoko 用本地 AniDB_Episode 表，
      // 即整部作品的集），文件身份只决定文件绑到哪个 eid；其它主源仍只有有身份
      // 的文件那几集。
      final _AnidbLinkSources allSources =
          metadata.provider == VideoMetadataProviderKind.anidb
              ? await _anidbWorkLinkSources(primaryHydration.metadata,
                  resolvedLookup, localWork, hashEvidence, warnings)
              : _anidbLinkSources(localWork, hashEvidence);
      // Shoko 对 UserVerified：该 AniDB 集不再参与匹配，它钉到的 TMDB 集也从
      // 候选池移除——否则同单元里更靠前的自动链接成员照样能被链到用户钉死的
      // 那一格，落库先到先得时钉死静默丢失。
      final _AnidbLinkSources sources =
          _withoutUserVerified(allSources, localWork, hashEvidence, userVerified);
      final Set<(int, int)> reservedCardKeys = <(int, int)>{
        for (final VideoEpisodeBindingOverrideRow row in userVerified.values)
          (row.seasonNumber, row.episodeNumber),
      };
      if (sources.isNotEmpty) {
        tmdbEpisodeAliases ??=
            await _tmdbEpisodeAliases(tmdbShow, warnings, localWork.title);
        final AnidbEpisodeLinkOutcome linked = linkAnidbEpisodesToTmdb(
          metadata,
          tmdbShow,
          sources.regular,
          specialSources: sources.specials,
          slices: await _cardSlices(metadata, expansion, resolvedLookup),
          candidateAliases: tmdbEpisodeAliases,
          preferredLanguage: _locale,
          reservedCardKeys: reservedCardKeys,
        );
        metadata = linked.work;
        final _AppliedAnidbLinks applied = _applyAnidbEpisodeLinks(
          localWork,
          hashEvidence,
          linked.links,
          linked.specialLinks,
          episodeOverrides,
          warnings,
          skipMembers: userVerified.keys.toSet(),
        );
        episodeOverrides = applied.overrides;
        anidbXrefs = <String, AnidbEpisodeXref>{...anidbXrefs, ...applied.xrefs};
        anidbAdditional = applied.additional;
      }
    }
    if (userVerified.isNotEmpty) {
      episodeOverrides = <String, (int, int)>{
        ...episodeOverrides,
        for (final VideoEpisodeBindingOverrideRow row in userVerified.values)
          row.bookUid: (row.seasonNumber, row.episodeNumber),
      };
      anidbXrefs = <String, AnidbEpisodeXref>{
        ...anidbXrefs,
        for (final MapEntry<String, AnidbFileIdentity> entry
            in hashEvidence.identities.entries)
          if (userVerified.containsKey(entry.key))
            entry.key: AnidbEpisodeXref(
              episodeId: entry.value.episodeId,
              episodeNumber: entry.value.episodeNumber,
              matchRating: kUserVerifiedMatchRating,
            ),
      };
      warnings.add(SourceScrapeIssue(
          workTitle: localWork.title,
          message:
              '${userVerified.length} 个文件按用户手动指定的季集绑定（UserVerified），本轮不改：'
              '${userVerified.values.map((VideoEpisodeBindingOverrideRow r) => '${p.basename(localWork.members.firstWhere((VideoBookRow m) => m.bookUid == r.bookUid).videoPath)} → 第 ${r.seasonNumber} 季第 ${r.episodeNumber} 集').join('、')}。'));
    }
    // AniDB 作品 id 由文件哈希直接确立（全部成员都指向同一 anime），不以
    // MAL 映射唯一为前提——那是 MAL 那边的事。唯一不写的情况是它与已确认的
    // MAL 身份明确冲突（上面已报警告）。
    if (hashEvidence.animeId != null && !hashContradictsCanonical) {
      metadata = _withAnidbId(metadata, hashEvidence.animeId!);
    } else if (offline != null && _resolvedFromOffline(metadata, offline)) {
      // 离线标题索引定的身份：把 AniDB id 一并落成交叉引用，下次不必再查索引。
      metadata = _withAnidbId(metadata, offline.anidbId);
    }
    metadata = _preserveHistoricalIdentities(
      metadata,
      <VideoMetadataLookup>[
        ...reusableLookups,
        if (confirmedLookup != null) confirmedLookup,
      ],
    );
    metadata = _selectImages(metadata);
    if (nfo != null) metadata = mergeNfoAuthority(nfo, metadata);
    resolvedWorkCache[cacheKey] = metadata;
    authoritativeSeasonEpisodesCache[cacheKey] = seasonEpisodesAuthoritative;
    _episodeOverridesCache[cacheKey] = episodeOverrides;
    _anidbXrefCache[cacheKey] = anidbXrefs;
    _anidbAdditionalCache[cacheKey] = anidbAdditional;
    _userVerifiedCache[cacheKey] = userVerified.keys.toSet();
    return _ResolvedWork(
      metadata: metadata,
      seasonEpisodesAuthoritative: seasonEpisodesAuthoritative,
      episodeOverrides: episodeOverrides,
      anidbEpisodeXrefs: anidbXrefs,
      anidbAdditionalBindings: anidbAdditional,
      userVerifiedBooks: userVerified.keys.toSet(),
    );
  }

  /// 来源池剔除用户钉死成员（UserVerified）的 AniDB 集：主集与一文件多集的
  /// 其余集都不再参与自动匹配（Shoko `TmdbLinkingService` 对 UserVerified 的
  /// 集直接跳过）。
  static _AnidbLinkSources _withoutUserVerified(
    _AnidbLinkSources sources,
    VideoSourceScrapeWork localWork,
    _HashWorkEvidence evidence,
    Map<String, VideoEpisodeBindingOverrideRow> userVerified,
  ) {
    if (userVerified.isEmpty || !sources.isNotEmpty) return sources;
    final Set<int> regular = <int>{};
    final Set<int> specials = <int>{};
    void collect(String epnoText) {
      if (_regularEpisodeNumber(epnoText) case final int epno) {
        regular.add(epno);
      } else if (_specialEpisodeNumber(epnoText) case final int special) {
        specials.add(special);
      }
    }

    for (final VideoBookRow member in localWork.members) {
      if (!userVerified.containsKey(member.bookUid)) continue;
      final AnidbFileIdentity? identity = evidence.identities[member.bookUid];
      if (identity == null) continue;
      collect(identity.episodeNumber);
      for (final AnidbEpisodeShare share in identity.otherEpisodes) {
        if (share.episodeNumber case final String epnoText) collect(epnoText);
      }
    }
    if (regular.isEmpty && specials.isEmpty) return sources;
    return _AnidbLinkSources(
      regular: <TmdbEpisodeMatchSource>[
        for (final TmdbEpisodeMatchSource source in sources.regular)
          if (!regular.contains(source.number)) source,
      ],
      specials: <TmdbEpisodeMatchSource>[
        for (final TmdbEpisodeMatchSource source in sources.specials)
          if (!specials.contains(source.number)) source,
      ],
    );
  }

  /// 成员哈希分属不同 AniDB 作品（Shoko：文件身份决定作品归属，一个目录里几部
  /// 作品就是几个 series）→ 按 AniDB 作品拆开各自刮：
  ///  - 电影型（AniDB 动画类型 `Movie`，FILE amask 取得；旧行没类型时看 Fribb
  ///    `isMovie`）→ 每个成员各自一个单文件电影单元（Shoko
  ///    `CrossRef_AniDB_TMDB_Movie`）；
  ///  - 其余（电视剧 / OVA / Web…）→ 每个 AniDB 作品**新建一个播放列表合集**
  ///    收下该组成员，作为 `collection:` 剧集单元刮——剧集作品以合集为锚、一合集
  ///    一部，所以对齐 Shoko 多 series 的方式就是把合集拆成多个。
  /// 原合集：视频成员全被拆走时整个删除（`deleteMediaCollectionWithAssets`，
  /// 写合集级墓碑，按文件名归组的重扫不再把它按原名重建）；否则只移走已拆成员
  /// 并清掉合集级作品残留。任一成员没有 AniDB 身份 → 空表（不能猜归属，保持
  /// 原「请拆分合集」待确认）；目录合集不在此路径（计划器不把它当剧集单元）。
  /// 身份按主源顺序给：有唯一 MAL id 用 MAL（TMDB 经映射兜底），否则 TMDB id，
  /// 都没有就让子单元自己按哈希 / 标题走常规识别。
  Future<List<_SplitWork>> _splitByAnidbWork(
    VideoSourceScrapeWork localWork,
    _HashWorkEvidence evidence,
    SourceLibraryRow? source, {
    required VideoMetadataProviderKind primaryProvider,
  }) async {
    final MediaCollectionRow? collection = localWork.collection;
    if (collection == null || collection.sourceFolderPath != null) {
      return const <_SplitWork>[];
    }
    // 按 AniDB 作品分组（保持成员顺序）。
    final Map<int, List<VideoBookRow>> groups = <int, List<VideoBookRow>>{};
    final Map<int, AnidbFileIdentity> identityByAnime =
        <int, AnidbFileIdentity>{};
    for (final VideoBookRow member in localWork.members) {
      final AnidbFileIdentity? identity = evidence.identities[member.bookUid];
      if (identity == null) return const <_SplitWork>[];
      (groups[identity.animeId] ??= <VideoBookRow>[]).add(member);
      identityByAnime.putIfAbsent(identity.animeId, () => identity);
    }
    if (groups.length < 2) return const <_SplitWork>[];

    // 先决定每组形态与身份（不动库）。
    final List<_PlannedSplitGroup> planned = <_PlannedSplitGroup>[
      for (final MapEntry<int, List<VideoBookRow>> group in groups.entries)
        await _planAnidbGroup(
          animeId: group.key,
          members: group.value,
          identity: identityByAnime[group.key]!,
          primaryProvider: primaryProvider,
        ),
    ];

    // 原合集去留：视频成员全部被拆走 → 整删（带墓碑）；否则只移走已拆成员。
    final List<MediaCollectionItemRow> items =
        await database.getCollectionItems(collection.id);
    final Set<String> splitUids = <String>{
      for (final VideoBookRow member in localWork.members) member.bookUid,
    };
    final bool wholeCollection = items.every((MediaCollectionItemRow item) =>
        item.mediaType == MediaKind.video.dbValue &&
        splitUids.contains(item.entryKey));
    if (wholeCollection) {
      await deleteMediaCollectionWithAssets(database, collection.id);
    } else {
      for (final String uid in splitUids) {
        await database.removeFromCollection(collection.id, MediaKind.video, uid);
      }
      await _store.removeCollectionOwnedWork(collection.id);
      await database.deleteCollectionScrapeMeta(collection.id);
    }

    final List<_SplitWork> result = <_SplitWork>[];
    for (final _PlannedSplitGroup group in planned) {
      if (group.kind == VideoMetadataMediaKind.movie) {
        for (final VideoBookRow member in group.members) {
          result.add(_SplitWork(
            work: VideoSourceScrapeWork(
              source: source,
              title: group.title,
              members: <VideoBookRow>[member],
            ),
            lookup: group.lookup,
            animeId: group.animeId,
            kind: group.kind,
          ));
        }
        continue;
      }
      result.add(await _createAnidbEpisodicUnit(
        group,
        source,
        replacingCollectionId: collection.id,
      ));
    }
    return result;
  }

  /// Shoko：AnimeSeries 只按 AniDB anime id 建一次、多文件复用
  /// （`AnimeSeriesRepository.GetByAnimeID`），文件在哪个目录、叫什么名字与归属
  /// 无关。计划器只按合集成员关系出单元，于是散在合集外的单文件 `book:` 单元哪怕
  /// 哈希全指向同一部剧，也各自成「一集的电视剧」：作品行一集一份、tvshow / season
  /// sidecar 永远写不出（单成员单元证明不了专属根目录）、日志一集四条（BUG-2624）。
  /// 这里在主循环前把它们按 AniDB 作品合成 playlist 合集剧集单元，与
  /// [_splitByAnidbWork] 互为镜像：拆分建合集怎么建，合并就怎么建。
  ///
  /// 只动 **单文件、非电影、没有已确认身份** 的单元：电影一文件一作品是 Shoko 的
  /// `CrossRef_AniDB_TMDB_Movie` 形态，不合；带已确认身份的单元是用户或上一轮
  /// 定过的，不静默改键。哈希识别不了 / 关闭 / 未配置的文件原样留给主循环按既有
  /// 路径处理（那边会打出具体原因）。
  Future<List<VideoSourceScrapeWork>> _mergeStandaloneByAnidbWork(
    List<VideoSourceScrapeWork> works,
    SourceLibraryRow source, {
    required Map<String, VideoMetadataLookup> lookups,
    required List<SourceScrapeIssue> warnings,
    required VideoSourceScrapeCancellationToken token,
    required void Function(String path, int bytes, int totalBytes)
        onHashProgress,
    required VideoMetadataProviderKind primaryProvider,
  }) async {
    _preIdentified.clear();
    if (!hashIdentityService.enabled || !hashIdentityService.isConfigured) {
      return works;
    }
    final Map<int, List<VideoSourceScrapeWork>> byAnime =
        <int, List<VideoSourceScrapeWork>>{};
    final Map<int, AnidbFileIdentity> identityByAnime =
        <int, AnidbFileIdentity>{};
    for (final VideoSourceScrapeWork work in works) {
      if (work.isEpisodic || lookups.containsKey(work.stableKey)) continue;
      // 与主循环同一优先级：已落库 / NFO / 路径显式 id 在哈希之前。这些单元留给
      // 主循环按既有路径处理（哈希照做、但不决定身份、更不改合集归属）。
      if (await _hasAuthoritativeIdentity(work, source)) continue;
      final VideoBookRow member = work.members.single;
      token.throwIfCancelled();
      final AnidbHashIdentityResult result =
          await hashIdentityService.identifyFile(
        member.videoPath,
        isCancelled: () => token.isCancelled,
        onProgress: (int bytes, int total) =>
            onHashProgress(member.videoPath, bytes, total),
      );
      token.throwIfCancelled();
      if (result.status == AnidbHashIdentityStatus.cancelled) {
        throw const VideoSourceScrapeCancelled();
      }
      // 结果（含未命中 / 失败）留给主循环的 [_identifyWork] 复用：那边负责打
      // 每个文件的识别日志，这里不重复识别、不重复记账。
      _preIdentified[member.videoPath] = result;
      final AnidbFileIdentity? identity = result.identity;
      if (result.status != AnidbHashIdentityStatus.matched ||
          identity == null) {
        continue;
      }
      (byAnime[identity.animeId] ??= <VideoSourceScrapeWork>[]).add(work);
      identityByAnime.putIfAbsent(identity.animeId, () => identity);
    }

    final Map<String, _SplitWork> mergedByFirstKey = <String, _SplitWork>{};
    final Set<String> absorbedKeys = <String>{};
    for (final MapEntry<int, List<VideoSourceScrapeWork>> entry
        in byAnime.entries) {
      if (entry.value.length < 2) continue;
      final List<VideoBookRow> members = <VideoBookRow>[
        for (final VideoSourceScrapeWork work in entry.value)
          work.members.single,
      ]..sort((VideoBookRow a, VideoBookRow b) =>
          a.videoPath.toLowerCase().compareTo(b.videoPath.toLowerCase()));
      final _PlannedSplitGroup group = await _planAnidbGroup(
        animeId: entry.key,
        members: members,
        identity: identityByAnime[entry.key]!,
        primaryProvider: primaryProvider,
      );
      if (group.kind == VideoMetadataMediaKind.movie) continue;
      // 用户删过同名播放列表就不自动重建（BUG-1739 的规矩：非用户显式的合集创建
      // 路径都要问墓碑）。[createMediaCollection] 本身会清墓碑——它是给用户显式
      // 重建用的入口；合并预处理每趟刮削都跑，不问墓碑就是「删除合集（保留条目）
      // → 下一趟又按 AniDB 标题建回来」的死循环，用户视角＝合集删不掉。
      if (await database.hasCollectionDeletionTombstone(
        group.title,
        'playlist',
      )) {
        warnings.add(SourceScrapeIssue(
          workTitle: group.title,
          message:
              'AniDB 文件哈希把 ${members.length} 个独立文件识别为同一部作品（aid ${entry.key}，${group.title}），'
              '但同名播放列表合集已被删除过，不自动重建；文件保持独立。要合并请手动新建合集。',
        ));
        continue;
      }
      token.throwIfCancelled();
      final _SplitWork merged = await _createAnidbEpisodicUnit(group, source);
      mergedByFirstKey[entry.value.first.stableKey] = merged;
      for (final VideoSourceScrapeWork work in entry.value) {
        absorbedKeys.add(work.stableKey);
      }
      if (merged.lookup case final VideoMetadataLookup lookup) {
        lookups[merged.work.stableKey] = lookup;
      }
      warnings.add(SourceScrapeIssue(
        workTitle: merged.work.title,
        message:
            'AniDB 文件哈希把 ${members.length} 个独立文件识别为同一部作品（aid ${entry.key}，${group.title}），'
            '已按 Shoko 方式合成剧集合集「${merged.work.title}」再刮削。',
      ));
    }
    if (mergedByFirstKey.isEmpty) return works;
    // 合并单元顶替其第一个成员原来的位置，其余被吸收的单元移除；顺序不变。
    return List<VideoSourceScrapeWork>.unmodifiable(<VideoSourceScrapeWork>[
      for (final VideoSourceScrapeWork work in works)
        if (mergedByFirstKey[work.stableKey] case final _SplitWork merged)
          merged.work
        else if (!absorbedKeys.contains(work.stableKey))
          work,
    ]);
  }

  /// 主循环让哈希决定作品身份的前提是「已确认 / 已落库 / NFO / 路径显式 id 都
  /// 没有」（[_resolveWork] 的 `hashDecidesIdentity`）。合并预处理跑在主循环之前，
  /// 必须按同一优先级放行：用户手动确认过的散文件（身份持久在 book 级作品行）若被
  /// 按哈希合进新合集，落库时 `_removeBookOwnedWorksForCollection` 会把那一行连同
  /// 用户的确认一起删掉——哈希静默换掉了手动指定的身份，正是拆分路径明文禁止的
  /// 事，合并路径没有理由例外。
  Future<bool> _hasAuthoritativeIdentity(
    VideoSourceScrapeWork work,
    SourceLibraryRow source,
  ) async {
    final VideoBookRow member = work.members.single;
    if (parseExplicitVideoMetadataIds(
      <String>[member.videoPath],
      fallbackMediaKind: VideoMetadataMediaKind.tv,
    ).isNotEmpty) {
      return true;
    }
    final List<VideoMetadataLookup> stored = await _store.lookupsForWork(work);
    if (stored.any((VideoMetadataLookup lookup) =>
        kSelectableVideoMetadataProviders.contains(lookup.provider))) {
      return true;
    }
    final VideoMetadataWork? nfo = await VideoNfoReader(
      generatedArtifactChecker:
          DatabaseSidecarGeneratedArtifactChecker(database),
    ).readForPaths(
      sourceRoot: source.rootPath,
      fallbackTitle: work.title,
      videoPaths: <String>[member.videoPath],
    );
    return _lookupsForNfo(nfo).isNotEmpty;
  }

  /// 一组哈希同属一部 AniDB 作品的成员 → 形态（电影 / 剧集）+ 身份。
  /// 形态由 AniDB 动画类型决定（FILE amask 取得），旧行没类型时看 Fribb `isMovie`；
  /// 身份按主源顺序给：AniDB 主源直接用 aid；否则有唯一 MAL id 用 MAL，再否则
  /// TMDB id；都没有就让单元自己按哈希 / 标题走常规识别。
  Future<_PlannedSplitGroup> _planAnidbGroup({
    required int animeId,
    required List<VideoBookRow> members,
    required AnidbFileIdentity identity,
    required VideoMetadataProviderKind primaryProvider,
  }) async {
    final AnimeIdentityMapping? mapping = identityMapping;
    final AnimeIdentityEntry? entry =
        mapping == null ? null : await mapping.entryForAnidb(animeId);
    final bool isMovie = identity.animeType.isNotEmpty
        ? identity.isMovieType
        : (entry?.isMovie ?? false);
    final VideoMetadataMediaKind kind =
        isMovie ? VideoMetadataMediaKind.movie : VideoMetadataMediaKind.tv;
    VideoMetadataLookup? lookup;
    if (primaryProvider == VideoMetadataProviderKind.anidb) {
      lookup = VideoMetadataLookup(
          provider: VideoMetadataProviderKind.anidb,
          externalId: '$animeId',
          mediaKind: kind);
    } else if (entry != null && entry.malIds.length == 1) {
      lookup = VideoMetadataLookup(
          provider: VideoMetadataProviderKind.mal,
          externalId: '${entry.malIds.single}',
          mediaKind: kind);
    } else if (entry != null &&
        entry.tmdbId != null &&
        entry.isMovie == (kind == VideoMetadataMediaKind.movie)) {
      lookup = VideoMetadataLookup(
          provider: VideoMetadataProviderKind.tmdb,
          externalId: '${entry.tmdbId}',
          mediaKind: kind);
    }
    final String title = <String>[
      identity.englishTitle,
      identity.romajiTitle,
      identity.kanjiTitle,
      members.first.title,
    ].map((String t) => t.trim()).firstWhere((String t) => t.isNotEmpty,
        orElse: () => members.first.title);
    return _PlannedSplitGroup(
      animeId: animeId,
      members: members,
      title: title,
      kind: kind,
      lookup: lookup,
    );
  }

  /// 剧集组 → 新建（撞名时加 AniDB 后缀）播放列表合集收下成员，作为
  /// `collection:` 剧集单元。[replacingCollectionId] 是拆分时正被拆掉的原合集：
  /// 与它同名不算撞名。
  Future<_SplitWork> _createAnidbEpisodicUnit(
    _PlannedSplitGroup group,
    SourceLibraryRow? source, {
    int? replacingCollectionId,
  }) async {
    String name = group.title;
    final MediaCollectionRow? clash =
        await database.getMediaCollectionByNaturalKey(name, 'playlist');
    if (clash != null && clash.id != replacingCollectionId) {
      name = '$name（AniDB ${group.animeId}）';
    }
    final int newId =
        await database.createMediaCollection(name, collectionType: 'playlist');
    for (final VideoBookRow member in group.members) {
      await database.addToCollection(newId, MediaKind.video, member.bookUid);
    }
    final MediaCollectionRow row =
        (await database.getMediaCollectionById(newId))!;
    return _SplitWork(
      work: VideoSourceScrapeWork(
        source: source,
        title: row.name,
        members: group.members,
        collection: row,
      ),
      lookup: group.lookup,
      animeId: group.animeId,
      kind: group.kind,
    );
  }

  static const String _hashDisabledNotice =
      'AniDB 哈希识别已关闭（设置 → 在线服务 → AniDB），本批只按标题识别。';

  Future<_HashWorkEvidence> _identifyWork(
    VideoSourceScrapeWork work,
    List<SourceScrapeIssue> warnings,
    VideoSourceScrapeCancellationToken token,
    void Function(String, int, int) onProgress,
  ) async {
    if (!hashIdentityService.enabled) {
      // 一批只提一次：用户排障时得看得出「没开」和「没配好」不是一回事。
      if (!warnings.any(
          (SourceScrapeIssue issue) => issue.message == _hashDisabledNotice)) {
        warnings.add(SourceScrapeIssue(
            workTitle: work.title, message: _hashDisabledNotice));
      }
      return const _HashWorkEvidence();
    }
    if (!hashIdentityService.isConfigured) {
      warnings.add(SourceScrapeIssue(
          workTitle: work.title,
          message:
              'AniDB 哈希识别未执行：哈希识别不可用，缺少账号或注册客户端配置。请填写用户名、密码及已注册的 client name/version；继续按标题刮削。'));
      return const _HashWorkEvidence();
    }
    final Set<int> animeIds = <int>{};
    final Set<int> mappedMalIds = <int>{};
    final Set<String> titles = <String>{};
    final Map<String, AnidbFileIdentity> identities =
        <String, AnidbFileIdentity>{};
    for (final VideoBookRow member in work.members) {
      token.throwIfCancelled();
      // 合并预处理（[_mergeStandaloneByAnidbWork]）已经识别过的文件直接复用，
      // 一个文件一批只识别一次；没经过预处理的（合集单元成员）照常现场识别。
      final AnidbHashIdentityResult result =
          _preIdentified.remove(member.videoPath) ??
              await hashIdentityService.identifyFile(
                member.videoPath,
                isCancelled: () => token.isCancelled,
                onProgress: (int bytes, int total) =>
                    onProgress(member.videoPath, bytes, total),
              );
      token.throwIfCancelled();
      if (result.status == AnidbHashIdentityStatus.cancelled) {
        throw const VideoSourceScrapeCancelled();
      }
      final AnidbFileIdentity? identity = result.identity;
      if (result.status == AnidbHashIdentityStatus.matched &&
          identity != null) {
        identities[member.bookUid] = identity;
        animeIds.add(identity.animeId);
        final Set<int> malIds = result.mapping?.malIds ?? const <int>{};
        mappedMalIds.addAll(malIds);
        titles.addAll(<String>[
          identity.romajiTitle,
          identity.kanjiTitle,
          identity.englishTitle
        ]
            .map((String title) => title.trim())
            .where((String title) => title.isNotEmpty));
        final String mappingNote = switch (malIds.length) {
          0 => '文件身份已确定，MAL 元数据映射未确定。',
          1 => 'MAL 作品映射=${malIds.single}。',
          _ => 'MAL 映射候选=${malIds.join('/')}（anime-lists 一对多，待确认）。',
        };
        // Shoko `CrossRef_File_Episode` / `ReleaseInfo.IsCorrupted` 对应的三条
        // 文件级事实：一文件多集、AniDB 标过时、CRC 不符。多集文件的其余集与
        // 主集一样进 TMDB 逐集链接、绑成额外的分集行（v110 一文件多绑定）；
        // 集信息还没问到的只能先记 eid。
        final String fileNotes = <String>[
          if (identity.otherEpisodes.isNotEmpty)
            '本文件还覆盖 AniDB 集 ${identity.otherEpisodes.map((AnidbEpisodeShare s) => '${s.episodeNumber == null ? '' : '${s.episodeNumber} / '}eid ${s.episodeId}（${s.percentage}%）').join('、')}'
                '${identity.hasUnresolvedOtherEpisodes ? '；其余集集信息尚未取到，本轮只绑主集' : '；与主集一并链接 TMDB、同一文件绑多集'}。',
          if (identity.isDeprecated) 'AniDB 已把这份文件标为过时版本（有更新版本或已撤下）。',
          if (identity.crcMatches == false)
            'AniDB 登记的 CRC 与这份文件不符（可能损坏或非官方版本）。',
          if (identity.fileVersion > 1) '文件版本 v${identity.fileVersion}。',
        ].join();
        warnings.add(SourceScrapeIssue(
            workTitle: work.title,
            message:
                'AniDB ED2K 文件识别${result.fromStore ? '（已记录，未重算）' : '成功'}：${p.basename(member.videoPath)}; '
                'hash=${result.matchedEd2k ?? result.hash?.ed2k}; fileId=${identity.fileId}; animeId=${identity.animeId}; '
                'episodeId=${identity.episodeId}; episodeNumber=${identity.episodeNumber}'
                '${identity.episodeAirDate == null ? '' : '; aired=${identity.episodeAirDate}'}。'
                '$mappingNote'
                '季集由 AniDB 集在 TMDB 逐集链接决定（Shoko 式），不推断 MAL 集号。'
                '$fileNotes'
                '${result.episodeInfoError == null ? '' : '集播出日补问失败（${result.episodeInfoError}），本轮只按集标题链接。'}'));
      } else if (result.status != AnidbHashIdentityStatus.disabled) {
        warnings.add(SourceScrapeIssue(
            workTitle: work.title,
            message:
                '${p.basename(member.videoPath)}：${_hashFailureReason(result)}'
                '继续严格标题识别。'));
      }
    }
    return _HashWorkEvidence(
      animeId: animeIds.length == 1 ? animeIds.single : null,
      malId: animeIds.length == 1 && mappedMalIds.length == 1
          ? mappedMalIds.single
          : null,
      mappedMalIds: animeIds.length == 1 ? mappedMalIds : const <int>{},
      titles: titles.toList(growable: false),
      // 只有「成员分属不同 AniDB 作品」才是真冲突；MAL 映射一对多由候选确认消解。
      conflicting: animeIds.length > 1,
      identities: identities,
    );
  }

  /// Fribb 一对多：把每个候选 MAL id 按 id 直拉成候选作品；拉不到的跳过（记
  /// 一条说明），全拉不到就退回 AniDB 原生标题搜索。
  Future<List<VideoMetadataWork>> _fetchMappedMalCandidates(
    _HashWorkEvidence evidence,
    VideoMetadataMediaKind kind,
    List<SourceScrapeIssue> warnings,
    VideoSourceScrapeWork work,
  ) async {
    final VideoMetadataProvider? mal =
        _registry.provider(VideoMetadataProviderKind.mal);
    if (mal == null || !mal.isAvailable) return const <VideoMetadataWork>[];
    final List<VideoMetadataWork> candidates = <VideoMetadataWork>[];
    for (final int malId in evidence.mappedMalIds.toList()..sort()) {
      try {
        final VideoMetadataWork? candidate = await mal.fetchWork(
            VideoMetadataLookup(
                provider: VideoMetadataProviderKind.mal,
                externalId: '$malId',
                mediaKind: kind));
        if (candidate != null) candidates.add(candidate);
      } catch (error) {
        warnings.add(SourceScrapeIssue(
            workTitle: work.title,
            message: 'AniDB ${evidence.animeId} 的映射候选 MAL $malId 拉取失败：$error'));
      }
    }
    return candidates;
  }

  /// 离线标题索引阶段：唯一精确命中才返回身份；歧义 / 查无 / 不可用都只记一条
  /// 说明并返回 null，让在线链继续，绝不因离线数据拉不到而判整条失败。
  Future<AnimeOfflineIdentity?> _identifyOffline(
    List<String> titles,
    VideoMetadataMediaKind kind,
    List<SourceScrapeIssue> warnings,
    VideoSourceScrapeWork work, {
    required VideoMetadataProviderKind primaryProvider,
  }) async {
    final AnimeOfflineIdentityResolver? resolver = offlineIdentityResolver;
    if (resolver == null) return null;
    final AnimeOfflineIdentityResolution resolution = await resolver.resolve(
      titleCandidates: titles,
      mediaKind: kind,
    );
    switch (resolution.status) {
      case AnimeOfflineIdentityStatus.matched:
        final AnimeOfflineIdentity identity = resolution.identity!;
        // AniDB 主源：离线索引命中的 aid 本身就是主源身份，不要求映射表有 MAL/TMDB。
        if (!identity.hasOnlineIdentity &&
            !_providerChain(primaryProvider)
                .contains(VideoMetadataProviderKind.anidb)) {
          warnings.add(SourceScrapeIssue(
              workTitle: work.title,
              message:
                  '离线标题索引命中 AniDB ${identity.anidbId}（${identity.matchedTitle}），但跨站映射表里没有它的 MAL/TMDB id；继续在线标题搜索。'));
          return null;
        }
        return identity;
      case AnimeOfflineIdentityStatus.ambiguous:
        warnings.add(SourceScrapeIssue(
            workTitle: work.title,
            message: '离线标题索引有多个同名候选，不自动决定（${resolution.reason}）；继续在线标题搜索。'));
        return null;
      case AnimeOfflineIdentityStatus.unavailable:
        warnings.add(SourceScrapeIssue(
            workTitle: work.title,
            message: '离线标题索引不可用（${resolution.reason}）；继续在线标题搜索。'));
        return null;
      case AnimeOfflineIdentityStatus.notFound:
        return null;
    }
  }

  /// 多季一张卡（设计稿 B）。MAL 一个 id = 一季；本地合集出现「非首季的季号」或
  /// 「超过首季集数的绝对集号」时：
  /// 1. Fribb：MAL id → 同一 TMDB 剧 → 该剧全部季条目（按偏移排序 = 本地季序）；
  /// 2. 每个需要的季按各自 MAL id 拉季/集资料并重编到本地季号；
  /// 3. 绝对集号先查 anime-relations 显式表，没有规则再按各季集数累加折算；
  ///    落进多目标、续作集数未知、超出全部已知季 → 不折算，只记说明（Sonarr /
  ///    Taiga：歧义即放弃，交人工）。
  /// 单季作品（没有季号提示、集号不越界）零成本直接返回。
  Future<_SeasonExpansion> _expandMalSeasons({
    required VideoSourceScrapeWork localWork,
    required VideoMetadataWork primary,
    required VideoMetadataLookup primaryLookup,
    required List<SourceScrapeIssue> warnings,
    Map<String, int> episodeOffsets = const <String, int>{},
  }) async {
    const _SeasonExpansion none = _SeasonExpansion();
    final AnimeIdentityMapping? mapping = identityMapping;
    final VideoMetadataProviderKind namespace = primaryLookup.provider;
    if (namespace != VideoMetadataProviderKind.mal &&
        namespace != VideoMetadataProviderKind.anidb) {
      return none;
    }
    final VideoMetadataProvider? provider = _registry.provider(namespace);
    final int? primaryId = int.tryParse(primaryLookup.externalId);
    if (mapping == null || provider == null || primaryId == null) return none;
    // 同一函数服务两套主源命名空间：条目在 MAL 侧要 malIds 唯一，在 AniDB 侧就是
    // anidbId。
    int? idOf(AnimeIdentityEntry entry) =>
        namespace == VideoMetadataProviderKind.mal
            ? (entry.malIds.length == 1 ? entry.malIds.single : null)
            : entry.anidbId;
    final String label =
        namespace == VideoMetadataProviderKind.mal ? 'MAL' : 'AniDB';

    // 识别词的集偏移已经先于本步生效：这里看到的集号是纠正后的编号，跨季
    // 折算才不会拿错编号去累加。
    final Map<String, ({int? season, int? episode})> parsedMembers =
        <String, ({int? season, int? episode})>{
      for (final VideoBookRow member in localWork.members)
        member.bookUid: _shiftedEpisodeKey(
          parseVideoPath(member.videoPath),
          episodeOffsets[member.bookUid] ?? 0,
        ),
    };
    final int primaryCount = primary.episodeCount ??
        primary.seasons.firstOrNull?.episodes.length ??
        0;
    final bool anySeasonHint = parsedMembers.values.any(
        (({int? season, int? episode}) info) =>
            info.season != null && info.season != 1);
    final bool anyBeyond = parsedMembers.values.any(
        (({int? season, int? episode}) info) =>
            info.season == null &&
            info.episode != null &&
            primaryCount > 0 &&
            info.episode! > primaryCount);
    if (!anySeasonHint && !anyBeyond) return none;

    final List<AnimeIdentityEntry> seasonEntries;
    int? relationsMalId;
    try {
      final List<AnimeIdentityEntry> own =
          namespace == VideoMetadataProviderKind.mal
              ? await mapping.entriesForMal(primaryId)
              : <AnimeIdentityEntry>[
                  if (await mapping.entryForAnidb(primaryId)
                      case final AnimeIdentityEntry entry)
                    entry,
                ];
      final Set<int> tmdbIds = <int>{
        for (final AnimeIdentityEntry entry in own)
          if (entry.tmdbId case final int id)
            if (!entry.isMovie) id,
      };
      if (tmdbIds.length != 1) {
        warnings.add(SourceScrapeIssue(
            workTitle: localWork.title,
            message:
                '多季映射：$label $primaryId 在跨站映射表里没有唯一的 TMDB 剧 id，各季无法自动对齐；只保留当前季的分集资料。'));
        return none;
      }
      seasonEntries = <AnimeIdentityEntry>[
        for (final AnimeIdentityEntry entry
            in await mapping.entriesForTmdbTv(tmdbIds.single))
          if (entry.tmdbSeason != 0 && idOf(entry) != null) entry,
      ];
      // anime-relations 显式表按 MAL id 记规则：AniDB 主源时用本条目映到的唯一 MAL。
      relationsMalId = namespace == VideoMetadataProviderKind.mal
          ? primaryId
          : (own.singleOrNull?.malIds.length == 1
              ? own.single.malIds.single
              : null);
    } on Object catch (error) {
      warnings.add(SourceScrapeIssue(
          workTitle: localWork.title,
          message: '多季映射表不可用（$error）；只保留当前季的分集资料。'));
      return none;
    }
    final int primaryIndex = seasonEntries
        .indexWhere((AnimeIdentityEntry entry) => idOf(entry) == primaryId);
    if (primaryIndex < 0) {
      warnings.add(SourceScrapeIssue(
          workTitle: localWork.title,
          message: '多季映射：$label $primaryId 不在其 TMDB 剧的季条目序列里，各季无法自动对齐。'));
      return none;
    }
    final int primarySeasonNumber = primaryIndex + 1;

    final Map<int, VideoMetadataWork?> worksByIndex = <int, VideoMetadataWork?>{
      primaryIndex: primary,
    };
    VideoMetadataLookup lookupAt(int index) => VideoMetadataLookup(
          provider: namespace,
          externalId: '${idOf(seasonEntries[index])}',
          mediaKind: VideoMetadataMediaKind.tv,
        );
    Future<VideoMetadataWork?> workAt(int index) async {
      if (worksByIndex.containsKey(index)) return worksByIndex[index];
      VideoMetadataWork? work;
      try {
        work = await provider.fetchWork(lookupAt(index));
      } on Object catch (error) {
        if (!_isProviderFailure(error)) rethrow;
      }
      return worksByIndex[index] = work;
    }

    final Map<String, (int, int)> overrides = <String, (int, int)>{};
    final Set<int> neededIndexes = <int>{};
    bool complete = true;
    // 「第 S 季第 E 集」先按映射表的 TVDB / TMDB 季号 + 集偏移解析（同一个
    // TVDB 季常常装着多个 MAL cour：Bleach 千年血战篇四个 cour 都是 tvdb S17，
    // 偏移 0/13/26/40）。命中后本地集号减偏移就是那个 cour 的集号。缓存按
    // (季, 集) 去重，同一季一批文件只算一次。
    final Map<(int, int), Future<_MappedSeasonHit?>> seasonHits =
        <(int, int), Future<_MappedSeasonHit?>>{};
    Future<_MappedSeasonHit?> resolveSeasonHint(int season, int episode) =>
        seasonHits[(season, episode)] ??= _resolveMappedSeasonHit(
          seasonEntries,
          season: season,
          episode: episode,
          primaryIndex: primaryIndex,
          primaryCount: primaryCount,
          workAt: workAt,
          warnings: warnings,
          localTitle: localWork.title,
        );
    for (final MapEntry<String, ({int? season, int? episode})> entry
        in parsedMembers.entries) {
      final ({int? season, int? episode}) info = entry.value;
      final int? episode = info.episode;
      if (episode == null) continue;
      if (info.season case final int season) {
        final _MappedSeasonHit? hit = await resolveSeasonHint(season, episode);
        if (hit != null) {
          if (hit.index == null) {
            // 映射表认识这一季，但集号落不进任何 cour 的范围（续作还没进表）。
            complete = false;
            continue;
          }
          final int index = hit.index!;
          overrides[entry.key] = (index + 1, hit.episode);
          if (index != primaryIndex) neededIndexes.add(index);
          continue;
        }
        // 映射表对这一季没有 TVDB / TMDB 季号信息：退回「条目序号 = 本地季序」。
        final int index = season - 1;
        if (index == primaryIndex) continue;
        if (index >= 0 && index < seasonEntries.length) {
          neededIndexes.add(index);
        } else {
          complete = false;
          warnings.add(SourceScrapeIssue(
              workTitle: localWork.title,
              message: '第 $season 季超出该剧已知的 ${seasonEntries.length} 季，未自动对齐。'));
        }
        continue;
      }
      if (primaryCount <= 0 || episode <= primaryCount) {
        if (primarySeasonNumber != 1) {
          overrides[entry.key] = (primarySeasonNumber, episode);
        }
        continue;
      }
      // 绝对集号越过当前季：先查显式表，再按各季集数累加。
      (int, int)? target;
      final AnimeEpisodeRelationsCatalog? relations = episodeRelations;
      final int? malId = relationsMalId;
      if (relations != null && malId != null) {
        try {
          final AnimeEpisodeRedirection? redirect =
              await relations.redirect(malId: malId, episode: episode);
          if (redirect != null && redirect.malId != malId) {
            final int index = seasonEntries.indexWhere(
                (AnimeIdentityEntry e) => e.malIds.contains(redirect.malId));
            if (index >= 0) target = (index, redirect.episode);
          }
        } on Object {
          // 显式表拉不到就退到累加法；不因为一张表挂了放弃整季。
        }
      }
      if (target == null) {
        int remaining = episode - primaryCount;
        for (int index = primaryIndex + 1;
            index < seasonEntries.length;
            index++) {
          final int? count = (await workAt(index))?.episodeCount;
          if (count == null || count <= 0) break;
          if (remaining <= count) {
            target = (index, remaining);
            break;
          }
          remaining -= count;
        }
      }
      if (target == null) {
        complete = false;
        warnings.add(SourceScrapeIssue(
            workTitle: localWork.title,
            path: localWork.members
                .firstWhere((VideoBookRow m) => m.bookUid == entry.key)
                .videoPath,
            message: '绝对集号 $episode 超出已知各季集数或续作集数未知，未自动折算；保留原编号待人工确认。'));
        continue;
      }
      overrides[entry.key] = (target.$1 + 1, target.$2);
      neededIndexes.add(target.$1);
    }

    final List<VideoMetadataSeason> extra = <VideoMetadataSeason>[];
    final List<VideoMetadataCredit> extraCredits = <VideoMetadataCredit>[];
    for (final int index in neededIndexes.toList()..sort()) {
      if (index == primaryIndex) continue;
      final VideoMetadataWork? work = await workAt(index);
      if (work == null) {
        complete = false;
        warnings.add(SourceScrapeIssue(
            workTitle: localWork.title,
            message:
                '第 ${index + 1} 季（$label ${idOf(seasonEntries[index])}）资料拉取失败，该季分集暂缺。'));
        continue;
      }
      // MAL 一个 cour 一个条目，各自只列本 cour 的声优 / 职员；卡片是整部作品，
      // 后续 cour 新登场角色的声优也要进作品级人物表（BUG-2612）。
      extraCredits.addAll(work.credits);
      final VideoMetadataLookup lookup = lookupAt(index);
      List<VideoMetadataSeason> seasons = const <VideoMetadataSeason>[];
      List<VideoMetadataEpisode> episodes = const <VideoMetadataEpisode>[];
      try {
        seasons = await provider.fetchSeasons(lookup);
        episodes = await provider.fetchEpisodes(lookup, seasonNumber: 1);
      } on Object catch (error) {
        if (!_isProviderFailure(error)) rethrow;
        complete = false;
        warnings.add(SourceScrapeIssue(
            workTitle: localWork.title,
            message: '第 ${index + 1} 季分集资料抓取失败：$error'));
      }
      final VideoMetadataSeason base = seasons.firstOrNull ??
          VideoMetadataSeason(
            seasonNumber: 1,
            title: work.title,
            episodeCount: work.episodeCount,
            ids: work.ids,
          );
      final int seasonNumber = index + 1;
      extra.add(base.copyWith(
        seasonNumber: seasonNumber,
        ids: base.ids.isEmpty ? work.ids : base.ids,
        episodeCount: base.episodeCount ?? work.episodeCount ?? episodes.length,
        episodes: <VideoMetadataEpisode>[
          for (final VideoMetadataEpisode episode in episodes)
            episode.copyWith(seasonNumber: seasonNumber),
        ],
      ));
    }
    return _SeasonExpansion(
      primarySeasonNumber: primarySeasonNumber,
      extraSeasons: extra,
      extraCredits: extraCredits,
      episodeOverrides: overrides,
      complete: complete,
      // 全部条目都带上（不只本地出现的季）：MAL 没给集数时，切片终点要靠同一
      // TMDB 季里下一个 cour 的偏移。
      tmdbSlices: <int, TmdbSeasonSlice>{
        for (int index = 0; index < seasonEntries.length; index++)
          if (seasonEntries[index].tmdbSeason case final int tmdbSeason)
            index + 1: (
              tmdbSeason: tmdbSeason,
              offset: seasonEntries[index].tmdbEpisodeOffset ?? 0,
            ),
      },
    );
  }

  /// 把本地「第 [season] 季第 [episode] 集」按映射表解析成「第几个条目的第几集」。
  ///
  /// 候选 = TVDB 季号等于 [season] 的条目（按 tvdb 偏移）∪ TMDB 季号等于
  /// [season] 的条目（按 tmdb 偏移）；同一命名空间内取偏移最大且仍小于集号的
  /// 条目，再用该条目的集数验一次落不落得进去（集数未知视为落得进）。
  /// TVDB 与 TMDB 各自解出不同结果时取 TVDB（Sonarr / Plex 式 `Season NN` 目录
  /// 几乎都是 TVDB 编号）并记一条说明。
  ///
  /// 返回 `null` = 映射表对这一季没有任何季号信息，调用方退回序号法；返回
  /// `index == null` = 映射表认识这一季但集号落不进任何条目（已记警告）。
  static Future<_MappedSeasonHit?> _resolveMappedSeasonHit(
    List<AnimeIdentityEntry> seasonEntries, {
    required int season,
    required int episode,
    required int primaryIndex,
    required int primaryCount,
    required Future<VideoMetadataWork?> Function(int index) workAt,
    required List<SourceScrapeIssue> warnings,
    required String localTitle,
  }) async {
    Future<({int index, int episode})?> resolveIn(
      int? Function(AnimeIdentityEntry entry) seasonOf,
      int? Function(AnimeIdentityEntry entry) offsetOf,
    ) async {
      int? bestIndex;
      int bestOffset = -1;
      for (int index = 0; index < seasonEntries.length; index++) {
        final AnimeIdentityEntry entry = seasonEntries[index];
        if (seasonOf(entry) != season) continue;
        final int offset = offsetOf(entry) ?? 0;
        if (offset < episode && offset > bestOffset) {
          bestOffset = offset;
          bestIndex = index;
        }
      }
      if (bestIndex == null) return null;
      final int local = episode - bestOffset;
      final int count = bestIndex == primaryIndex
          ? primaryCount
          : (await workAt(bestIndex))?.episodeCount ?? 0;
      if (count > 0 && local > count) return null;
      return (index: bestIndex, episode: local);
    }

    final bool known = seasonEntries.any((AnimeIdentityEntry entry) =>
        entry.tvdbSeason == season || entry.tmdbSeason == season);
    if (!known) return null;
    final ({int index, int episode})? tvdb = await resolveIn(
      (AnimeIdentityEntry entry) => entry.tvdbSeason,
      (AnimeIdentityEntry entry) => entry.tvdbEpisodeOffset,
    );
    final ({int index, int episode})? tmdb = await resolveIn(
      (AnimeIdentityEntry entry) => entry.tmdbSeason,
      (AnimeIdentityEntry entry) => entry.tmdbEpisodeOffset,
    );
    final ({int index, int episode})? hit = tvdb ?? tmdb;
    if (hit == null) {
      warnings.add(SourceScrapeIssue(
          workTitle: localTitle,
          message: '第 $season 季第 $episode 集不在跨站映射表已知的各季集范围内（续作可能尚未入表），未自动对齐。'));
      return const _MappedSeasonHit(index: null, episode: 0);
    }
    if (tvdb != null && tmdb != null && tvdb != tmdb) {
      warnings.add(SourceScrapeIssue(
          workTitle: localTitle,
          message:
              '第 $season 季第 $episode 集按 TVDB 与 TMDB 编号解出不同的季集，已按 TVDB 编号对齐；若目录按 TMDB 编号请手动确认。'));
    }
    return _MappedSeasonHit(index: hit.index, episode: hit.episode);
  }

  static bool _isUsableResolution(VideoMetadataResolution resolution) =>
      resolution.status == VideoMetadataResolutionStatus.matched ||
      resolution.status == VideoMetadataResolutionStatus.ambiguous;

  /// 身份接力（Jellyfin `MergeNewData` 的思路）：主源是 MAL 而本地还没有任何
  /// TMDB 身份时，用 Fribb 映射把 MAL id 换成 TMDB 剧/电影 id，让 TMDB 补充按
  /// id 直拉而不是再按标题搜一次（少一次歧义机会，也不吃 TMDB 搜索配额）。
  /// 映射不唯一或拉不到映射表时返回 null，退回原有的标题补充路径。
  Future<VideoMetadataLookup?> _tmdbLookupFromMapping(
    VideoMetadataLookup? resolved,
    VideoMetadataMediaKind kind,
  ) async {
    final AnimeIdentityMapping? mapping = identityMapping;
    if (mapping == null ||
        resolved == null ||
        (resolved.provider != VideoMetadataProviderKind.mal &&
            resolved.provider != VideoMetadataProviderKind.anidb)) {
      return null;
    }
    final int? primaryId = int.tryParse(resolved.externalId);
    if (primaryId == null) return null;
    try {
      final List<AnimeIdentityEntry> entries =
          resolved.provider == VideoMetadataProviderKind.anidb
              ? <AnimeIdentityEntry>[
                  if (await mapping.entryForAnidb(primaryId)
                      case final AnimeIdentityEntry entry)
                    entry,
                ]
              : await mapping.entriesForMal(primaryId);
      final Set<int> tmdbIds = <int>{
        for (final AnimeIdentityEntry entry in entries)
          if (entry.tmdbId case final int id)
            if (entry.isMovie == (kind == VideoMetadataMediaKind.movie)) id,
      };
      if (tmdbIds.length != 1) return null;
      return VideoMetadataLookup(
        provider: VideoMetadataProviderKind.tmdb,
        externalId: '${tmdbIds.single}',
        mediaKind: kind,
      );
    } on Object {
      return null;
    }
  }

  /// 最终资料是否就是离线索引指到的那部作品（MAL id 或 TMDB id 对得上）。
  static bool _resolvedFromOffline(
    VideoMetadataWork work,
    AnimeOfflineIdentity offline,
  ) {
    final String? malId =
        _lookupForCandidate(work, VideoMetadataProviderKind.mal)?.externalId;
    final String? tmdbId =
        _lookupForCandidate(work, VideoMetadataProviderKind.tmdb)?.externalId;
    final String? anidbId =
        _lookupForCandidate(work, VideoMetadataProviderKind.anidb)?.externalId;
    return (offline.malId != null && malId == '${offline.malId}') ||
        (offline.tmdbId != null && tmdbId == '${offline.tmdbId}') ||
        anidbId == '${offline.anidbId}';
  }

  /// Shoko `TmdbSearchService.GetAnimePrequelChainRoot`：沿 MAL Prequel 关系回溯到
  /// 系列根作品（最多 8 跳，环路 / 拉不到即停），返回根作品的标题与别名；
  /// 根就是自己或没有关系能力时为空。
  Future<List<String>> _prequelRootTitles(VideoMetadataWork primary) async {
    final VideoMetadataProvider? provider =
        _registry.provider(VideoMetadataProviderKind.mal);
    final VideoMetadataLookup? start =
        _lookupForCandidate(primary, VideoMetadataProviderKind.mal);
    if (provider is! VideoMetadataRelationsProvider || start == null) {
      return const <String>[];
    }
    final VideoMetadataRelationsProvider relations =
        provider as VideoMetadataRelationsProvider;
    final Set<String> visited = <String>{start.externalId};
    VideoMetadataLookup current = start;
    try {
      for (int hop = 0; hop < 8; hop++) {
        final List<VideoMetadataLookup> prequels =
            await relations.fetchPrequels(current);
        final VideoMetadataLookup? next = prequels
            .where((VideoMetadataLookup l) => visited.add(l.externalId))
            .firstOrNull;
        if (next == null) break;
        current = next;
      }
      if (current.externalId == start.externalId) return const <String>[];
      final VideoMetadataWork? root = await provider!.fetchWork(current);
      if (root == null) return const <String>[];
      return <String>[
        root.title,
        if (root.originalTitle case final String original) original,
        ...root.aliases,
      ];
    } on Object catch (error) {
      if (!_isProviderFailure(error)) rethrow;
      return const <String>[];
    }
  }

  /// Shoko `TmdbSearchService` 的季打分：每个候选剧取「集数与 MAL 作品集数最接近
  /// 的非特典季」，差值最小者胜；同差值再比该季首播与 MAL 首播 ±3 天。打不出
  /// 唯一赢家返回 null（继续交人工）。
  Future<VideoMetadataWork?> _pickTmdbCandidateBySeason(
    VideoMetadataProvider tmdb,
    List<VideoMetadataWork> candidates,
    VideoMetadataWork primary,
  ) async {
    final int? count = primary.episodeCount;
    if (count == null || count <= 0 || candidates.length > 5) return null;
    final DateTime? premiered = primary.premiered == null
        ? null
        : DateTime.tryParse(primary.premiered!);
    VideoMetadataWork? best;
    int bestDiff = 1 << 30;
    bool bestDateHit = false;
    bool tie = false;
    for (final VideoMetadataWork candidate in candidates) {
      final VideoMetadataLookup? lookup =
          _lookupForCandidate(candidate, VideoMetadataProviderKind.tmdb);
      if (lookup == null) continue;
      VideoMetadataWork? full;
      try {
        full = await tmdb.fetchWork(lookup);
      } on Object catch (error) {
        if (!_isProviderFailure(error)) rethrow;
      }
      if (full == null) continue;
      int diff = 1 << 30;
      bool dateHit = false;
      for (final VideoMetadataSeason season in full.seasons) {
        if (season.seasonNumber == 0 || season.episodeCount == null) continue;
        final int d = (season.episodeCount! - count).abs();
        final DateTime? aired =
            season.airDate == null ? null : DateTime.tryParse(season.airDate!);
        final bool hit = premiered != null &&
            aired != null &&
            premiered.difference(aired).inDays.abs() <= 3;
        if (d < diff || (d == diff && hit && !dateHit)) {
          diff = d;
          dateHit = hit;
        }
      }
      if (diff < bestDiff || (diff == bestDiff && dateHit && !bestDateHit)) {
        best = full;
        bestDiff = diff;
        bestDateHit = dateHit;
        tie = false;
      } else if (diff == bestDiff && dateHit == bestDateHit) {
        tie = true;
      }
    }
    return tie || best == null || bestDiff == 1 << 30 ? null : best;
  }

  /// 有没有「映射表没切片、且分集还没挂 TMDB id」的 MAL 季要做逐集匹配。
  static bool _needsEpisodeMatch(VideoMetadataWork metadata, Set<int> sliced) =>
      metadata.seasons.any((VideoMetadataSeason season) =>
          season.seasonNumber != 0 &&
          !sliced.contains(season.seasonNumber) &&
          season.episodes.any((VideoMetadataEpisode episode) => !episode.ids
              .any((VideoMetadataId id) => id.type.toLowerCase() == 'tmdb')));

  /// TMDB 剧每个正片季的 en-US / 原语集名（`VideoMetadataEpisodeAliasProvider`）；
  /// 拉不到只记一条说明，匹配退回只比资料语言的集名。
  Future<Map<(int, int), List<String>>> _tmdbEpisodeAliases(
    VideoMetadataWork tmdb,
    List<SourceScrapeIssue> warnings,
    String localTitle,
  ) async {
    final VideoMetadataProvider? provider =
        _registry.provider(VideoMetadataProviderKind.tmdb);
    final String? tmdbId =
        _lookupForCandidate(tmdb, VideoMetadataProviderKind.tmdb)?.externalId;
    if (provider is! VideoMetadataEpisodeAliasProvider || tmdbId == null) {
      return const <(int, int), List<String>>{};
    }
    final VideoMetadataLookup lookup = VideoMetadataLookup(
      provider: VideoMetadataProviderKind.tmdb,
      externalId: tmdbId,
      mediaKind: VideoMetadataMediaKind.tv,
      episodeGroupId: tmdb.episodeGroupId,
    );
    final Map<(int, int), List<String>> aliases = <(int, int), List<String>>{};
    for (final VideoMetadataSeason season in tmdb.seasons) {
      if (season.seasonNumber == 0 || season.episodes.isEmpty) continue;
      try {
        final Map<int, List<String>> bySeason =
            await (provider as VideoMetadataEpisodeAliasProvider)
                .fetchEpisodeTitleAliases(lookup,
                    seasonNumber: season.seasonNumber);
        for (final MapEntry<int, List<String>> entry in bySeason.entries) {
          aliases[(season.seasonNumber, entry.key)] = entry.value;
        }
      } on Object catch (error) {
        if (!_isProviderFailure(error)) rethrow;
        warnings.add(SourceScrapeIssue(
            workTitle: localTitle,
            message:
                'TMDB 第 ${season.seasonNumber} 季多语言集名拉取失败（$error），逐集核对只比资料语言的集名。'));
      }
    }
    return aliases;
  }

  /// 主源分级是否成人向：MAL / Jikan `Rx - Hentai`，AniDB `restricted` 映射的
  /// `R18+`，以及 TMDB 自己的 `adult` 折成的 `R18+`。`R+ - Mild Nudity` 不算。
  @visibleForTesting
  static bool isAdultContentRating(String? contentRating) {
    final String rating = (contentRating ?? '').trim().toUpperCase();
    return rating.startsWith('RX') || rating.startsWith('R18');
  }

  /// AniDB epno 的正片集号（`S1` / `C2` / `T1` 等特典前缀 → null）。
  static int? _anidbEpisodeNumber(AnidbFileIdentity? identity) {
    if (identity == null) return null;
    final int? number = int.tryParse(identity.episodeNumber.trim());
    return number == null || number <= 0 ? null : number;
  }

  /// AniDB epno 的 `S` 型特典序号（`S3` → 3）；正片与 C/T/P/O → null。Shoko
  /// 只把 Episode + Special 拿去和 TMDB 对，C/T/P/O 不进池。
  static int? _anidbSpecialNumber(AnidbFileIdentity? identity) {
    if (identity == null) return null;
    final RegExpMatch? match =
        RegExp(r'^S(\d+)$').firstMatch(identity.episodeNumber.trim());
    final int? number = match == null ? null : int.tryParse(match.group(1)!);
    return number == null || number <= 0 ? null : number;
  }

  /// 「卡片季号 → AniDB 来源集」：只收 (a) 该季在 [metadata] 里存在且一集都没有、
  /// (b) 不在映射表切片里、(c) 成员有 AniDB 身份且是正片的成员。
  static Map<int, List<TmdbEpisodeMatchSource>> _anidbEpisodeSources(
    VideoSourceScrapeWork localWork,
    _HashWorkEvidence evidence,
    Map<String, (int, int)> episodeOverrides,
    VideoMetadataWork metadata,
    Set<int> slicedSeasons,
  ) {
    final Set<int> emptySeasons = <int>{
      for (final VideoMetadataSeason season in metadata.seasons)
        if (season.seasonNumber != 0 &&
            season.episodes.isEmpty &&
            !slicedSeasons.contains(season.seasonNumber))
          season.seasonNumber,
    };
    if (emptySeasons.isEmpty) {
      return const <int, List<TmdbEpisodeMatchSource>>{};
    }
    final Map<int, Map<int, TmdbEpisodeMatchSource>> result =
        <int, Map<int, TmdbEpisodeMatchSource>>{};
    for (final VideoBookRow member in localWork.members) {
      final AnidbFileIdentity? identity = evidence.identities[member.bookUid];
      final int? epno = _anidbEpisodeNumber(identity);
      final (int, int)? key = localEpisodeKeyFor(member, episodeOverrides);
      if (identity == null || epno == null || key == null) continue;
      if (!emptySeasons.contains(key.$1)) continue;
      (result[key.$1] ??= <int, TmdbEpisodeMatchSource>{})[epno] =
          _anidbMatchSource(identity, epno);
    }
    return <int, List<TmdbEpisodeMatchSource>>{
      for (final MapEntry<int, Map<int, TmdbEpisodeMatchSource>> entry
          in result.entries)
        entry.key: entry.value.values.toList(growable: false),
    };
  }

  /// 一条 AniDB 文件身份 → 逐集匹配器的来源集（集号 + 三语集标题 + 播出日）。
  static TmdbEpisodeMatchSource _anidbMatchSource(
          AnidbFileIdentity identity, int epno) =>
      TmdbEpisodeMatchSource(
        number: epno,
        titles: <String>[
          identity.episodeTitle,
          identity.episodeRomajiTitle,
          identity.episodeKanjiTitle,
        ].where((String title) => title.trim().isNotEmpty).toList(),
        airDate: identity.episodeAirDate,
      );

  /// 一文件多集里「其余集」（EPISODE 已答）→ 来源集。
  static TmdbEpisodeMatchSource _shareMatchSource(
          AnidbEpisodeShare share, int epno) =>
      TmdbEpisodeMatchSource(
        number: epno,
        titles: share.titles,
        airDate: share.airDate,
      );

  /// AniDB epno 文本 → 正片集号（`04` → 4）；特典 / 非法 → null。
  static int? _regularEpisodeNumber(String epno) {
    final int? number = int.tryParse(epno.trim());
    return number == null || number <= 0 ? null : number;
  }

  /// AniDB epno 文本 → `S` 型特典序号（`S3` → 3）；其它 → null。
  static int? _specialEpisodeNumber(String epno) {
    final RegExpMatch? match = RegExp(r'^S(\d+)$').firstMatch(epno.trim());
    final int? number = match == null ? null : int.tryParse(match.group(1)!);
    return number == null || number <= 0 ? null : number;
  }

  /// Shoko 主路径的来源集：全部带 AniDB 身份的成员，正片按集号、`S` 型特典按
  /// 特典序号各自去重（同一集的 v1/v2 两个文件是同一来源集），**不看文件名**。
  /// C/T/P/O 型不进任何池（Shoko 同）。
  static _AnidbLinkSources _anidbLinkSources(
    VideoSourceScrapeWork localWork,
    _HashWorkEvidence evidence,
  ) {
    final Map<int, TmdbEpisodeMatchSource> regular =
        <int, TmdbEpisodeMatchSource>{};
    final Map<int, TmdbEpisodeMatchSource> specials =
        <int, TmdbEpisodeMatchSource>{};
    for (final VideoBookRow member in localWork.members) {
      final AnidbFileIdentity? identity = evidence.identities[member.bookUid];
      if (identity == null) continue;
      if (_anidbEpisodeNumber(identity) case final int epno) {
        regular.putIfAbsent(epno, () => _anidbMatchSource(identity, epno));
      } else if (_anidbSpecialNumber(identity) case final int special) {
        specials.putIfAbsent(
            special, () => _anidbMatchSource(identity, special));
      }
      // 一文件多集：其余集（集信息已问到的）与主集同池、同一条评分链。
      for (final AnidbEpisodeShare share in identity.otherEpisodes) {
        final String? epnoText = share.episodeNumber;
        if (epnoText == null) continue;
        if (_regularEpisodeNumber(epnoText) case final int epno) {
          regular.putIfAbsent(epno, () => _shareMatchSource(share, epno));
        } else if (_specialEpisodeNumber(epnoText) case final int special) {
          specials.putIfAbsent(
              special, () => _shareMatchSource(share, special));
        }
      }
    }
    return _AnidbLinkSources(
      regular: regular.values.toList(growable: false),
      specials: specials.values.toList(growable: false),
    );
  }

  /// AniDB 主源的 Shoko 式来源池：anime XML 里整部作品的正片（季 1）与 `S` 型
  /// 特典（季 0），每集带播出日 + 全部语言集名（provider 的别名能力）；再并上
  /// 文件身份给的集（同集号不重复）。XML 拉不到就退回只用文件身份。
  Future<_AnidbLinkSources> _anidbWorkLinkSources(
    VideoMetadataWork anidbWork,
    VideoMetadataLookup lookup,
    VideoSourceScrapeWork localWork,
    _HashWorkEvidence evidence,
    List<SourceScrapeIssue> warnings,
  ) async {
    final _AnidbLinkSources fromFiles =
        _anidbLinkSources(localWork, evidence);
    if (lookup.provider != VideoMetadataProviderKind.anidb) return fromFiles;
    final VideoMetadataProvider? provider =
        _registry.provider(VideoMetadataProviderKind.anidb);
    Future<Map<int, List<String>>> aliasesOf(int seasonNumber) async {
      if (provider is! VideoMetadataEpisodeAliasProvider) {
        return const <int, List<String>>{};
      }
      try {
        return await (provider as VideoMetadataEpisodeAliasProvider)
            .fetchEpisodeTitleAliases(lookup, seasonNumber: seasonNumber);
      } on Object catch (error) {
        warnings.add(SourceScrapeIssue(
            workTitle: localWork.title,
            message: 'AniDB 集名别名拉取失败（$error），逐集链接只用资料语言集名。'));
        return const <int, List<String>>{};
      }
    }
    final Map<int, TmdbEpisodeMatchSource> regular =
        <int, TmdbEpisodeMatchSource>{
      for (final TmdbEpisodeMatchSource source in fromFiles.regular)
        source.number: source,
    };
    final Map<int, TmdbEpisodeMatchSource> specials =
        <int, TmdbEpisodeMatchSource>{
      for (final TmdbEpisodeMatchSource source in fromFiles.specials)
        source.number: source,
    };
    for (final VideoMetadataSeason season in anidbWork.seasons) {
      if (season.seasonNumber != 0 && season.seasonNumber != 1) continue;
      final Map<int, TmdbEpisodeMatchSource> pool =
          season.seasonNumber == 0 ? specials : regular;
      final Map<int, List<String>> aliases = await aliasesOf(season.seasonNumber);
      for (final VideoMetadataEpisode episode in season.episodes) {
        // 文件身份里的那几集也并上 XML 的集名 / 播出日：FILE 只给三语集名、
        // 播出日常缺，XML 是同一集更全的一份，合并而不是二选一。
        final TmdbEpisodeMatchSource? fromFile = pool[episode.episodeNumber];
        pool[episode.episodeNumber] = TmdbEpisodeMatchSource(
          number: episode.episodeNumber,
          titles: metadataUniqueStrings(<String?>[
            ...?fromFile?.titles,
            episode.title,
            ...?aliases[episode.episodeNumber],
          ]),
          airDate: fromFile?.airDate ?? episode.airDate,
        );
      }
    }
    return _AnidbLinkSources(
      regular: regular.values.toList(growable: false),
      specials: specials.values.toList(growable: false),
    );
  }

  /// 卡片季 → TMDB 切片：多季扩展给的整套；单季卡片时用主 MAL 条目在映射表里
  /// 的 `season.tmdb` / `episode_offset.tmdb` 钉到卡片唯一的正片季上。没有
  /// 映射信息就空表（链接只能靠已带 TMDB id 的卡片集或 TMDB 主源换算）。
  Future<Map<int, TmdbSeasonSlice>> _cardSlices(
    VideoMetadataWork metadata,
    _SeasonExpansion? expansion,
    VideoMetadataLookup lookup,
  ) async {
    // 备选排序下 TMDB 剧的 (季, 集) 是分组编排，Fribb 切片说的是默认编排——两套
    // 编号对不上，切片一律不用（TMDB 主源直用分组 (季, 集)；MAL 主源只能靠已
    // 带 TMDB id 的卡片集换算）。
    if (metadata.episodeGroupId != null) {
      return const <int, TmdbSeasonSlice>{};
    }
    if (expansion != null && expansion.tmdbSlices.isNotEmpty) {
      return expansion.tmdbSlices;
    }
    final AnimeIdentityMapping? mapping = identityMapping;
    final int? primaryId = lookup.provider == VideoMetadataProviderKind.mal ||
            lookup.provider == VideoMetadataProviderKind.anidb
        ? int.tryParse(lookup.externalId)
        : null;
    if (mapping == null || primaryId == null) {
      return const <int, TmdbSeasonSlice>{};
    }
    final List<VideoMetadataSeason> regular = <VideoMetadataSeason>[
      for (final VideoMetadataSeason season in metadata.seasons)
        if (season.seasonNumber != 0) season,
    ];
    if (regular.length != 1) return const <int, TmdbSeasonSlice>{};
    final List<AnimeIdentityEntry> entries;
    try {
      final List<AnimeIdentityEntry> own =
          lookup.provider == VideoMetadataProviderKind.anidb
              ? <AnimeIdentityEntry>[
                  if (await mapping.entryForAnidb(primaryId)
                      case final AnimeIdentityEntry entry)
                    entry,
                ]
              : await mapping.entriesForMal(primaryId);
      entries = <AnimeIdentityEntry>[
        for (final AnimeIdentityEntry entry in own)
          if (!entry.isMovie && entry.tmdbSeason != null) entry,
      ];
    } on Object {
      // 映射表拉不到：本步只是换算辅助，链接仍可经卡片已有 TMDB id 落地。
      return const <int, TmdbSeasonSlice>{};
    }
    if (entries.length != 1) return const <int, TmdbSeasonSlice>{};
    return <int, TmdbSeasonSlice>{
      regular.single.seasonNumber: (
        tmdbSeason: entries.single.tmdbSeason!,
        offset: entries.single.tmdbEpisodeOffset ?? 0,
      ),
    };
  }

  /// 把链接落成成员覆盖：有 AniDB 正片身份的成员，卡片 (季, 集) 以链接为准；
  /// 与文件名解出的键不同时记一条说明（Shoko：文件名不参与识别）。落不下来
  /// （`cardKey == null`）的链接只记说明、保留原键。
  static _AppliedAnidbLinks _applyAnidbEpisodeLinks(
    VideoSourceScrapeWork localWork,
    _HashWorkEvidence evidence,
    Map<int, AnidbTmdbEpisodeLink> links,
    Map<int, AnidbTmdbEpisodeLink> specialLinks,
    Map<String, (int, int)> episodeOverrides,
    List<SourceScrapeIssue> warnings, {
    Set<String> skipMembers = const <String>{},
  }) {
    final Map<String, AnidbEpisodeXref> xrefs = <String, AnidbEpisodeXref>{};
    final Map<String, Map<(int, int), AnidbEpisodeXref>> additional =
        <String, Map<(int, int), AnidbEpisodeXref>>{};
    if (links.isEmpty && specialLinks.isEmpty) {
      return _AppliedAnidbLinks(episodeOverrides, xrefs, additional);
    }
    Map<String, (int, int)> result = episodeOverrides;
    int linkedCount = 0, corrected = 0, extraBindings = 0;
    final Map<TmdbEpisodeMatchRating, int> ratings =
        <TmdbEpisodeMatchRating, int>{};
    AnidbTmdbEpisodeLink? linkFor(String epnoText) {
      if (_regularEpisodeNumber(epnoText) case final int epno) {
        return links[epno];
      }
      if (_specialEpisodeNumber(epnoText) case final int special) {
        return specialLinks[special];
      }
      return null;
    }
    for (final VideoBookRow member in localWork.members) {
      final AnidbFileIdentity? identity = evidence.identities[member.bookUid];
      if (identity == null) continue;
      // 用户手动钉死的成员（UserVerified）：主集与其余集都不由自动链接决定。
      if (skipMembers.contains(member.bookUid)) continue;
      // 一文件多集：其余集各自成链、各自落成同一文件的额外绑定（Shoko
      // `CrossRef_File_Episode` 一文件多条）。主集没链上不影响其余集。
      for (final AnidbEpisodeShare share in identity.otherEpisodes) {
        final String? epnoText = share.episodeNumber;
        if (epnoText == null) continue;
        final AnidbTmdbEpisodeLink? extra = linkFor(epnoText);
        final (int, int)? extraKey = extra?.cardKey;
        if (extra == null || extraKey == null) continue;
        final (int, int)? primaryKey = linkFor(identity.episodeNumber)?.cardKey ??
            localEpisodeKeyFor(member, result);
        if (extraKey == primaryKey) continue;
        (additional[member.bookUid] ??= <(int, int), AnidbEpisodeXref>{})[
            extraKey] = AnidbEpisodeXref(
          episodeId: share.episodeId,
          episodeNumber: epnoText,
          matchRating: extra.rating.name,
        );
        extraBindings++;
        ratings[extra.rating] = (ratings[extra.rating] ?? 0) + 1;
        warnings.add(SourceScrapeIssue(
            workTitle: localWork.title,
            path: member.videoPath,
            message:
                '${p.basename(member.videoPath)}：本文件还覆盖 AniDB 集 $epnoText（eid ${share.episodeId}），'
                '经 TMDB S${extra.tmdbEpisode.seasonNumber}E${extra.tmdbEpisode.episodeNumber} 对应到第 ${extraKey.$1} 季第 ${extraKey.$2} 集'
                '（${_ratingLabel(extra.rating)}），同一文件再绑一集。'));
      }
      final AnidbTmdbEpisodeLink? link = linkFor(identity.episodeNumber);
      if (link == null) continue;
      final VideoMetadataEpisode tmdb = link.tmdbEpisode;
      final (int, int)? cardKey = link.cardKey;
      if (cardKey == null) {
        warnings.add(SourceScrapeIssue(
            workTitle: localWork.title,
            path: member.videoPath,
            message:
                'AniDB 集 ${identity.episodeNumber}（eid ${identity.episodeId}）已对上 TMDB '
                'S${tmdb.seasonNumber}E${tmdb.episodeNumber}（${_ratingLabel(link.rating)}），'
                '但本卡片没有对应季（映射表无该季切片），保留文件名解析的季集。'));
        continue;
      }
      linkedCount++;
      ratings[link.rating] = (ratings[link.rating] ?? 0) + 1;
      xrefs[member.bookUid] = AnidbEpisodeXref(
        episodeId: identity.episodeId,
        episodeNumber: identity.episodeNumber,
        matchRating: link.rating.name,
      );
      final (int, int)? current = localEpisodeKeyFor(member, result);
      if (current == cardKey) continue;
      corrected++;
      result = <String, (int, int)>{...result, member.bookUid: cardKey};
      warnings.add(SourceScrapeIssue(
          workTitle: localWork.title,
          path: member.videoPath,
          message:
              '${p.basename(member.videoPath)}：文件名解析为 ${current == null ? '无季集' : '第 ${current.$1} 季第 ${current.$2} 集'}，'
              'AniDB 文件身份（集 ${identity.episodeNumber}${identity.episodeAirDate == null ? '' : '，播出 ${identity.episodeAirDate}'}）'
              '经 TMDB S${tmdb.seasonNumber}E${tmdb.episodeNumber} 对应到第 ${cardKey.$1} 季第 ${cardKey.$2} 集'
              '（${_ratingLabel(link.rating)}），按身份归位。'));
    }
    if (linkedCount > 0) {
      final String detail = <String>[
        for (final TmdbEpisodeMatchRating rating
            in TmdbEpisodeMatchRating.values)
          if (ratings[rating] case final int n) '${_ratingLabel(rating)} $n',
      ].join('、');
      warnings.add(SourceScrapeIssue(
          workTitle: localWork.title,
          message:
              'AniDB 文件身份 → TMDB 集逐集链接（Shoko 式）：$linkedCount 个文件对上（$detail）'
              '${corrected == 0 ? '，与文件名一致' : '，其中 $corrected 个与文件名不符、已按身份归位'}'
              '${extraBindings == 0 ? '' : '；一文件多集额外绑定 $extraBindings 条'}。'));
    }
    return _AppliedAnidbLinks(result, xrefs, additional);
  }

  /// 逐集核对结果的一条说明（按季汇总评级），零命中不记。
  static void _noteEpisodeMatches(
    List<SourceScrapeIssue> warnings,
    String localTitle,
    Map<(int, int), TmdbEpisodeMatchRating> ratings, {
    required String how,
  }) {
    if (ratings.isEmpty) return;
    final Map<int, Map<TmdbEpisodeMatchRating, int>> bySeason =
        <int, Map<TmdbEpisodeMatchRating, int>>{};
    for (final MapEntry<(int, int), TmdbEpisodeMatchRating> entry
        in ratings.entries) {
      final Map<TmdbEpisodeMatchRating, int> counts =
          bySeason[entry.key.$1] ??= <TmdbEpisodeMatchRating, int>{};
      counts[entry.value] = (counts[entry.value] ?? 0) + 1;
    }
    for (final int season in bySeason.keys.toList()..sort()) {
      final Map<TmdbEpisodeMatchRating, int> counts = bySeason[season]!;
      final String detail = <String>[
        for (final TmdbEpisodeMatchRating rating
            in TmdbEpisodeMatchRating.values)
          if (counts[rating] case final int n) '${_ratingLabel(rating)} $n',
      ].join('、');
      warnings.add(SourceScrapeIssue(
          workTitle: localTitle,
          message:
              '第 $season 季 $how 在 TMDB 逐集核对（Shoko 式）：对上 ${counts.values.fold(0, (int a, int b) => a + b)} 集（$detail）。'));
    }
  }

  static String _ratingLabel(TmdbEpisodeMatchRating rating) => switch (rating) {
        TmdbEpisodeMatchRating.dateAndTitle => '标题+日期',
        TmdbEpisodeMatchRating.title => '标题',
        TmdbEpisodeMatchRating.dateAndTitleKinda => '近似标题+日期',
        TmdbEpisodeMatchRating.date => '日期',
        TmdbEpisodeMatchRating.titleKinda => '近似标题',
        TmdbEpisodeMatchRating.dateKinda => '最近日期',
        TmdbEpisodeMatchRating.firstAvailable => '顺序兜底',
        TmdbEpisodeMatchRating.none => '无',
      };

  static VideoMetadataWork _withAnidbId(VideoMetadataWork work, int anidbId) =>
      work.copyWith(ids: <VideoMetadataId>[
        ...work.ids.where((VideoMetadataId id) => id.type != 'anidb'),
        VideoMetadataId(type: 'anidb', value: '$anidbId'),
      ]);

  static bool _sameLookup(
          VideoMetadataLookup first, VideoMetadataLookup second) =>
      first.provider == second.provider &&
      first.externalId == second.externalId &&
      first.mediaKind == second.mediaKind;

  static String _hashFailureReason(AnidbHashIdentityResult result) {
    if (result.status == AnidbHashIdentityStatus.notFound) {
      if (result.missExhausted) {
        return 'ED2K 已计算，AniDB 连续 ${result.missAttempts} 次未收录此文件哈希，不再自动复查。';
      }
      return result.missAttempts > 1
          ? 'ED2K 已计算，但 AniDB 未收录此文件哈希（已复查 ${result.missAttempts} 次，每日再问一次）。'
          : 'ED2K 已计算，但 AniDB 未收录此文件哈希。';
    }
    if (result.error case final AnidbUdpException error) {
      return switch (error.reason) {
        AnidbUdpFailure.authentication => 'AniDB 登录失败，请检查用户名和密码。',
        AnidbUdpFailure.unavailable ||
        AnidbUdpFailure.clientOutdated ||
        AnidbUdpFailure.clientBanned =>
          'AniDB 客户端不可用，请核对注册的客户端名称与版本。',
        AnidbUdpFailure.network =>
          'AniDB UDP 连接失败，请检查 UDP 9000 网络与防火墙；普通 HTTP 代理不能代替 UDP 连接。',
        // 超时 ≠ 封禁（Shoko 同样只重发一次就按超时上报）：本文件跳过、下次扫描
        // 重试；只有连续超时才进入退避，退避窗口内的文件报 backoff。
        AnidbUdpFailure.timeout => 'AniDB UDP 请求超时（同一报文已重发一次仍无应答），本文件跳过，下次扫描重试；'
            '持续超时请检查 UDP 9000 端口与防火墙。',
        AnidbUdpFailure.backoff =>
          'AniDB 连续无应答，已退避 ${_blockRemainingLabel()}，本文件下次扫描重试。',
        AnidbUdpFailure.banned ||
        AnidbUdpFailure.maintenance =>
          'AniDB 当前限流或维护，已暂停请求 ${_blockRemainingLabel()}，请稍后重试。',
        _ => 'AniDB 未返回有效文件身份，请检查账号及客户端配置后重试。',
      };
    }
    return '无法完成 AniDB 文件识别，请确认文件可读且未被修改，并检查账号和网络配置。';
  }

  /// 进程级退避 / 封禁剩余时长的人话：`3 分钟` / `40 秒`。
  static String _blockRemainingLabel() {
    final Duration remaining = AnidbUdpFileClient.sharedBlockRemaining;
    if (remaining >= const Duration(minutes: 1)) {
      return '${(remaining.inSeconds / 60).ceil()} 分钟';
    }
    return '${remaining.inSeconds.clamp(1, 59)} 秒';
  }

  static bool _isProviderFailure(Object error) =>
      error is VideoMetadataProviderUnavailable ||
      error is VideoMetadataNetworkException ||
      error is TimeoutException ||
      error is SocketException ||
      error is HttpException ||
      error is TlsException ||
      error is http.ClientException;

  static bool _needsTmdbSupplement(
          VideoMetadataWork work, bool episodesComplete) =>
      (work.plot?.trim().isEmpty ?? true) ||
      work.credits.isEmpty ||
      hasIncompleteMalCredits(work) ||
      !work.images.any((VideoMetadataImage image) =>
          image.kind == VideoMetadataImageKind.cover) ||
      !work.images.any((VideoMetadataImage image) =>
          image.kind == VideoMetadataImageKind.backdrop) ||
      (work.kind == VideoMetadataMediaKind.tv &&
          (!episodesComplete || work.seasons.isEmpty));

  static List<VideoMetadataLookup> _lookupsForNfo(VideoMetadataWork? nfo) {
    if (nfo == null) return const <VideoMetadataLookup>[];
    final List<VideoMetadataId> ids = <VideoMetadataId>[
      ...nfo.ids.where((VideoMetadataId id) => id.isDefault),
      ...nfo.ids.where((VideoMetadataId id) => !id.isDefault),
    ];
    return <VideoMetadataLookup>[
      for (final VideoMetadataId id in ids)
        if (VideoMetadataProviderKind.values.asNameMap()[id.type]
            case final VideoMetadataProviderKind provider)
          VideoMetadataLookup(
            provider: provider,
            externalId: id.value,
            mediaKind: nfo.kind,
            episodeGroupId: nfo.episodeGroupId,
          ),
    ];
  }

  static VideoMetadataLookup? _lookupForProvider(
    Iterable<VideoMetadataLookup> lookups,
    VideoMetadataProviderKind provider,
  ) {
    for (final VideoMetadataLookup lookup in lookups) {
      if (lookup.provider == provider) return lookup;
    }
    return null;
  }

  static VideoMetadataWork _preserveTmdbIdentity(
    VideoMetadataWork primary,
    VideoMetadataLookup? persisted,
  ) {
    if (persisted == null ||
        persisted.provider != VideoMetadataProviderKind.tmdb ||
        persisted.mediaKind != primary.kind) {
      return primary;
    }
    final VideoMetadataId? current = primary.ids
        .where(
          (VideoMetadataId id) => id.type.trim().toLowerCase() == 'tmdb',
        )
        .firstOrNull;
    if (current != null && current.value.trim() != persisted.externalId) {
      // A fresh AniDB cross-reference explicitly changed. Do not attach the
      // episode group belonging to the old TMDB identity.
      return primary;
    }
    return primary.copyWith(
      ids: current == null
          ? <VideoMetadataId>[
              ...primary.ids,
              VideoMetadataId(type: 'tmdb', value: persisted.externalId),
            ]
          : primary.ids,
      episodeGroupId: primary.episodeGroupId ?? persisted.episodeGroupId,
    );
  }

  static VideoMetadataWork _preserveHistoricalIdentities(
    VideoMetadataWork primary,
    Iterable<VideoMetadataLookup> persisted,
  ) {
    final List<VideoMetadataId> ids = <VideoMetadataId>[...primary.ids];
    final Set<String> keys = <String>{
      for (final VideoMetadataId id in ids)
        '${id.type.trim().toLowerCase()}\u0000${id.value.trim()}',
    };
    for (final VideoMetadataLookup lookup in persisted) {
      if (lookup.provider == VideoMetadataProviderKind.local ||
          lookup.provider == VideoMetadataProviderKind.anidb ||
          lookup.provider == VideoMetadataProviderKind.mal ||
          lookup.provider == VideoMetadataProviderKind.tmdb) {
        continue;
      }
      final String value = lookup.externalId.trim();
      final String key = '${lookup.provider.name}\u0000$value';
      if (value.isEmpty || !keys.add(key)) continue;
      // Retired providers remain inert database cross references only. They
      // are never added to the resolver registry or contacted over network.
      ids.add(VideoMetadataId(type: lookup.provider.name, value: value));
    }
    return ids.length == primary.ids.length
        ? primary
        : primary.copyWith(ids: ids);
  }

  Future<_HydratedWork> _hydrateWork(
    VideoMetadataWork work,
    VideoMetadataLookup lookup,
    List<SourceScrapeIssue> warnings,
    String localTitle,
  ) async {
    final VideoMetadataProvider? provider = _registry.provider(lookup.provider);
    if (provider == null) {
      return _HydratedWork(metadata: work, complete: false);
    }
    if (provider.providerKind == VideoMetadataProviderKind.anidb &&
        work.rawPayload?[AniDbVideoMetadataProvider.catalogOnlyPayloadKey] ==
            true) {
      // 把「为什么」说出来（BUG-2623）：302 身份被拒 / 封禁 / 没配身份 / 传输
      // 失败在用户眼里是四种不同的下一步，吞成一句固定文案谁也查不下去。
      final String reason = provider is AniDbVideoMetadataProvider
          ? provider.httpDetailUnavailableReason
          : 'anime XML 未取到';
      warnings.add(SourceScrapeIssue(
        workTitle: localTitle,
        message: 'AniDB HTTP 详情不可用（$reason），已保留标题目录摘要且不会把分集标记为完整。',
      ));
      return _HydratedWork(metadata: work, complete: false);
    }
    bool complete = true;
    bool incompleteMalEpisodes = false;
    final bool isMal = provider.providerKind == VideoMetadataProviderKind.mal;
    List<VideoMetadataExtra> extras = work.extras;
    try {
      final List<VideoMetadataExtra> fetched = provider
              is VideoMetadataExtrasProvider
          ? await (provider as VideoMetadataExtrasProvider).fetchExtras(lookup)
          : const <VideoMetadataExtra>[];
      if (fetched.isNotEmpty) extras = fetched;
    } catch (error) {
      warnings.add(SourceScrapeIssue(
        workTitle: localTitle,
        message: '预告片与花絮抓取失败，作品资料仍已保留：$error',
      ));
    }
    if (work.kind == VideoMetadataMediaKind.movie) {
      return _HydratedWork(
        metadata: work.copyWith(extras: extras),
        complete: true,
      );
    }
    List<VideoMetadataSeason> seasons = work.seasons;
    try {
      final List<VideoMetadataSeason> fetched =
          await provider.fetchSeasons(lookup);
      if (isMal && fetched.isEmpty) incompleteMalEpisodes = true;
      if (fetched.isNotEmpty) seasons = fetched;
    } catch (error) {
      complete = false;
      warnings.add(SourceScrapeIssue(
        workTitle: localTitle,
        message: '季资料抓取失败，保留作品摘要：$error',
      ));
    }
    final List<VideoMetadataSeason> hydrated = <VideoMetadataSeason>[];
    for (final VideoMetadataSeason season in seasons) {
      List<VideoMetadataEpisode> episodes = season.episodes;
      try {
        final List<VideoMetadataEpisode> fetched = await provider.fetchEpisodes(
          lookup,
          seasonNumber: season.seasonNumber,
        );
        if (isMal && fetched.isEmpty) incompleteMalEpisodes = true;
        if (fetched.isNotEmpty) episodes = fetched;
      } catch (error) {
        complete = false;
        warnings.add(SourceScrapeIssue(
          workTitle: localTitle,
          message: '第 ${season.seasonNumber} 季分集资料抓取失败：$error',
        ));
      }
      hydrated.add(season.copyWith(
        episodes: episodes,
        episodeCount: season.episodeCount ?? episodes.length,
      ));
    }
    if (isMal) {
      final Set<(int, int)> episodeKeys = <(int, int)>{};
      for (final VideoMetadataSeason season in hydrated) {
        final Set<int> seasonEpisodes = <int>{
          for (final VideoMetadataEpisode episode in season.episodes)
            if (episode.episodeNumber > 0 && episode.title.trim().isNotEmpty)
              episode.episodeNumber,
        };
        episodeKeys.addAll(seasonEpisodes
            .map((int episode) => (season.seasonNumber, episode)));
        if (seasonEpisodes.isEmpty ||
            (season.episodeCount != null &&
                seasonEpisodes.length < season.episodeCount!)) {
          incompleteMalEpisodes = true;
        }
      }
      if (hydrated.isEmpty ||
          episodeKeys.isEmpty ||
          (work.episodeCount != null &&
              episodeKeys.length < work.episodeCount!)) {
        incompleteMalEpisodes = true;
      }
      if (incompleteMalEpisodes) {
        complete = false;
        warnings.add(SourceScrapeIssue(
            workTitle: localTitle,
            message: 'MAL 季集资料不完整：实际取得 ${episodeKeys.length} 集'
                '${work.episodeCount == null ? '' : '，作品声明 ${work.episodeCount} 集'}。'
                '保留已有季集记录，并尝试 TMDB 补充；空响应或缺集不作为删除依据。'));
      }
    }
    return _HydratedWork(
      metadata: work.copyWith(seasons: hydrated, extras: extras),
      complete: complete,
    );
  }

  Future<_TmdbSupplementResult> _tmdbSupplement(
    VideoMetadataWork primary,
    List<String> titles,
    int? seasonNumber,
    List<SourceScrapeIssue> warnings,
    String localTitle, {
    VideoMetadataLookup? lookupHint,
  }) async {
    final VideoMetadataProvider? tmdb =
        _registry.provider(VideoMetadataProviderKind.tmdb);
    if (tmdb == null || !tmdb.isAvailable) {
      return const _TmdbSupplementResult();
    }
    final bool incompatibleHint =
        lookupHint != null && lookupHint.mediaKind != primary.kind;
    VideoMetadataLookup? lookup = incompatibleHint ? null : lookupHint;
    for (final VideoMetadataId id in primary.ids) {
      if (id.type.toLowerCase() == 'tmdb') {
        lookup = VideoMetadataLookup(
          provider: VideoMetadataProviderKind.tmdb,
          externalId: id.value,
          mediaKind: primary.kind,
          episodeGroupId: primary.episodeGroupId,
        );
        break;
      }
    }
    if (lookup == null && incompatibleHint) {
      // A persisted/NFO TMDB id belongs to the other TMDB namespace. Do not
      // coerce movie ids into /tv/{id} (or vice versa), and do not silently
      // replace an explicit-but-incompatible binding with a title search.
      return const _TmdbSupplementResult();
    }
    VideoMetadataWork? work;
    try {
      if (lookup != null) {
        work = await tmdb.fetchWork(lookup);
      } else {
        // Shoko `TmdbSearchService`：沿 Prequel 链回溯到根作品，用根作品标题搜
        // （TMDB 一个剧 = 整个系列，cour 标题搜不到）；是续作就不带年份搜
        // （Shoko 的无年份查询变体：多季剧的 first_air_date 早于本季年份，
        // ±1 年的门会把整部剧挡掉）；仍歧义时按「集数最接近的季 + 该季首播
        // ±3 天」打分。
        final List<String> rootTitles = await _prequelRootTitles(primary);
        final List<String> candidates = <String>[
          primary.title,
          ...titles,
          ...rootTitles,
        ];
        final VideoMetadataResolution resolution =
            await VideoMetadataResolver(registry: registry)
                .resolve(VideoMetadataResolveRequest(
          selectedProvider: VideoMetadataProviderKind.tmdb,
          mediaKind: primary.kind,
          titleCandidates: candidates,
          year: rootTitles.isEmpty ? primary.year : null,
          seasonNumber: seasonNumber,
          // Shoko `includeRestricted: anime.IsRestricted`：主源已知成人向才
          // 让 TMDB 搜索放开 include_adult，其它作品维持 TMDB 默认过滤。
          includeAdult: isAdultContentRating(primary.contentRating),
        ));
        if (resolution.status == VideoMetadataResolutionStatus.matched) {
          work = resolution.work;
          lookup = resolution.lookup;
        } else if (resolution.status ==
            VideoMetadataResolutionStatus.ambiguous) {
          final VideoMetadataWork? scored = await _pickTmdbCandidateBySeason(
              tmdb, resolution.candidates, primary);
          if (scored != null) {
            work = scored;
            lookup =
                _lookupForCandidate(scored, VideoMetadataProviderKind.tmdb);
            warnings.add(SourceScrapeIssue(
              workTitle: localTitle,
              message:
                  'TMDB 补充源标题歧义（${resolution.candidates.length} 个候选），按集数最接近的季与首播日选了「${scored.title}」。',
            ));
          }
        }
      }
    } catch (error) {
      warnings.add(SourceScrapeIssue(
        workTitle: localTitle,
        message: 'TMDB 规范身份补充失败，主源资料仍已保留：$error',
      ));
      return const _TmdbSupplementResult();
    }
    if (work == null || lookup == null) {
      return const _TmdbSupplementResult();
    }
    try {
      final _HydratedWork hydrated =
          await _hydrateWork(work, lookup, warnings, localTitle);
      return _TmdbSupplementResult(metadata: hydrated.metadata);
    } catch (error) {
      warnings.add(SourceScrapeIssue(
        workTitle: localTitle,
        message: 'TMDB 季集骨架补充失败，主源资料仍已保留：$error',
      ));
      return _TmdbSupplementResult(metadata: work);
    }
  }

  VideoMetadataWork _selectImages(VideoMetadataWork metadata) {
    final List<VideoMetadataImage> primary = <VideoMetadataImage>[
      ...metadata.images,
      for (final VideoMetadataSeason season
          in metadata.seasons) ...<VideoMetadataImage>[
        ...season.images,
        for (final VideoMetadataEpisode episode in season.episodes)
          ...episode.images,
      ],
    ];
    final List<VideoMetadataImage> selected = selectVideoMetadataImages(
      primary: primary,
      // 本趟的有效资料语言（来源级覆盖 > 全局），与 TMDB 请求端的
      // include_image_language 同源——两端必须一致，否则请求回来的图会在选择
      // 阶段被另一套语言序重新排一遍。原语（Shoko `Main` 槽）由 provider 另拉一
      // 次补进候选池，这里同样插进语言序。
      languageOrder: VideoMetadataLanguages(_locale).imageLanguages,
      mainLanguage: VideoMetadataLanguages.primarySubtagOf(
          metadata.originalLanguage),
      maxPerKind: config.maxImagesPerKind,
    );
    final List<VideoMetadataSeason> seasons = <VideoMetadataSeason>[
      for (final VideoMetadataSeason season in metadata.seasons)
        season.copyWith(
          images: selected
              .where((VideoMetadataImage image) =>
                  image.seasonNumber == season.seasonNumber &&
                  image.episodeNumber == null)
              .toList(),
          episodes: <VideoMetadataEpisode>[
            for (final VideoMetadataEpisode episode in season.episodes)
              episode.copyWith(
                images: selected
                    .where((VideoMetadataImage image) =>
                        image.seasonNumber == episode.seasonNumber &&
                        image.episodeNumber == episode.episodeNumber)
                    .toList(),
              ),
          ],
        ),
    ];
    return metadata.copyWith(
      images: selected
          .where((VideoMetadataImage image) =>
              image.seasonNumber == null && image.episodeNumber == null)
          .toList(),
      seasons: seasons,
    );
  }

  /// 演职员头像落地（Shoko `AutoDownloadStaffImages` / `MaxAutoStaffImages`）：
  /// 开关开着时把作品级演职员的 TMDB 头像下到 `<video_covers>/people/`，回写
  /// `video_metadata_people.profile_path`；已落地的跳过，每部作品最多
  /// [kVideoMetadataMaxStaffImages] 张，失败只记说明不影响刮削结论。
  Future<void> _downloadStaffImages(
    VideoSourceScrapeWork localWork,
    VideoMetadataWork metadata,
    List<SourceScrapeIssue> warnings,
    VideoSourceScrapeCancellationToken cancellationToken,
  ) async {
    if (!config.downloadStaffImages || metadata.credits.isEmpty) return;
    Directory? directory;
    int downloaded = 0;
    final Set<String> seen = <String>{};
    for (final VideoMetadataCredit credit in metadata.credits) {
      if (downloaded >= kVideoMetadataMaxStaffImages) break;
      final String? url = credit.person.profileUrl?.trim();
      if (url == null || url.isEmpty) continue;
      final String personKey =
          VideoMetadataDatabaseStore.personKeyFor(credit.person);
      if (!seen.add(personKey)) continue;
      final VideoMetadataPersonRow? row =
          await database.getVideoMetadataPerson(personKey);
      if (row == null) continue;
      if (row.profilePath case final String existing
          when existing.isNotEmpty && File(existing).existsSync()) {
        downloaded++;
        continue;
      }
      cancellationToken.throwIfCancelled();
      final VideoMetadataDownloadedAsset asset;
      try {
        asset = await assetDownloader.download(url);
      } on VideoSourceScrapeCancelled {
        rethrow;
      } catch (error) {
        warnings.add(SourceScrapeIssue(
          workTitle: localWork.title,
          path: url,
          message: '人物照片下载失败（${credit.person.name}）：$error',
        ));
        continue;
      }
      directory ??= Directory(p.join(
          (await enginePaths.videoCoversDirectory()).path, 'people'));
      await directory.create(recursive: true);
      final String safeName =
          personKey.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
      // 与所有封面类落盘同一收口（写盘 + 解码缓存驱逐在 writer 里，守卫
      // media_cover_write_guard 不放行裸写）。
      final String destPath =
          p.join(directory.path, '$safeName.${asset.extension}');
      try {
        await writeCoverBytesAtomically(bytes: asset.bytes, destPath: destPath);
      } on CoverImageInvalidException catch (error) {
        warnings.add(SourceScrapeIssue(
          workTitle: localWork.title,
          path: url,
          message: '人物照片不是完整图片，未落地（${credit.person.name}）：$error',
        ));
        continue;
      }
      await database.updateVideoMetadataPersonProfilePath(personKey, destPath);
      downloaded++;
    }
  }

  Future<_SidecarOutcome> _writeSidecars({
    required SourceLibraryRow source,
    required int runId,
    required VideoSourceScrapeWork localWork,
    required VideoMetadataWork metadata,
    required PersistedVideoMetadata persisted,
    required List<String> knownSourcePaths,
    required _EffectiveSourceSettings settings,
    required VideoSourceScrapeCancellationToken cancellationToken,
    Map<String, (int, int)> episodeOverrides = const <String, (int, int)>{},
  }) async {
    if (!settings.writeNfo && !settings.writeImages) {
      return const _SidecarOutcome();
    }
    final List<SourceScrapeIssue> warnings = <SourceScrapeIssue>[];
    final List<SourceScrapeIssue> errors = <SourceScrapeIssue>[];
    final VideoSidecarLayout layout;
    if (metadata.kind == VideoMetadataMediaKind.movie) {
      layout = VideoSidecarTargetResolver.resolveMovie(
        sourceRoot: source.rootPath,
        videoPath: localWork.members.single.videoPath,
        knownSourceVideoPaths: knownSourcePaths,
      );
    } else {
      final List<VideoEpisodePath> members = <VideoEpisodePath>[];
      for (final VideoBookRow member in localWork.members) {
        final (int, int)? key = localEpisodeKeyFor(member, episodeOverrides);
        if (key == null) {
          warnings.add(SourceScrapeIssue(
            workTitle: localWork.title,
            path: member.videoPath,
            message: '无法从文件名确定集号，跳过该分集 sidecar',
          ));
          continue;
        }
        members.add(VideoEpisodePath(
          path: member.videoPath,
          seasonNumber: key.$1,
          episodeNumber: key.$2,
        ));
      }
      layout = VideoSidecarTargetResolver.resolveTv(
        sourceRoot: source.rootPath,
        members: members,
        knownSourceVideoPaths: knownSourcePaths,
      );
    }
    warnings.addAll(<SourceScrapeIssue>[
      for (final String warning in layout.warnings)
        SourceScrapeIssue(workTitle: localWork.title, message: warning),
    ]);

    final DatabaseSidecarArtifactStore artifacts = DatabaseSidecarArtifactStore(
      database: database,
      sourceId: source.id,
      runId: runId,
    );
    final VideoSidecarWriter writer = VideoSidecarWriter(
      sourceRoot: source.rootPath,
      artifactStore: artifacts,
    );
    final Map<String, _PlannedArtifact> planned = <String, _PlannedArtifact>{};

    void plan({
      required String path,
      required Uint8List bytes,
      required SidecarWritePolicy policy,
      required String kind,
      int? seasonId,
      int? episodeId,
      String? remoteUrl,
    }) {
      final _PlannedArtifact value = _PlannedArtifact(
        request: SidecarWriteRequest(
          targetPath: path,
          bytes: bytes,
          policy: policy,
          allowProtectedOverwrite: settings.allowExternalOverwrite,
        ),
        context: VideoSidecarArtifactContext(
          artifactKind: kind,
          writePolicy: policy.name,
          workId:
              seasonId == null && episodeId == null ? persisted.workId : null,
          seasonId: episodeId == null ? seasonId : null,
          episodeId: episodeId,
          fileSize: bytes.length,
          remoteUrl: remoteUrl,
        ),
      );
      planned[_pathKey(path)] = value;
      artifacts.register(path, value.context);
    }

    if (settings.writeNfo) {
      final SidecarWritePolicy policy = settings.nfoPolicy;
      if (layout.work case final VideoSidecarTarget target) {
        plan(
          path: target.nfoPath,
          bytes: VideoNfoBuilder.buildWork(metadata),
          policy: policy,
          kind: 'nfo',
        );
      }
      for (final VideoSidecarTarget target in layout.seasons) {
        final VideoMetadataSeason? season = metadata.seasons
            .where((VideoMetadataSeason value) =>
                value.seasonNumber == target.seasonNumber)
            .firstOrNull;
        if (season == null) continue;
        plan(
          path: target.nfoPath,
          bytes: VideoNfoBuilder.buildSeason(
            season,
            primaryProvider: metadata.provider,
          ),
          policy: policy,
          kind: 'nfo',
          seasonId: persisted.seasonIds[season.seasonNumber],
        );
      }
      for (final VideoSidecarTarget target in layout.episodes) {
        final VideoMetadataEpisode episode =
            _episode(metadata, target.seasonNumber!, target.episodeNumber!) ??
                VideoMetadataEpisode(
                  seasonNumber: target.seasonNumber!,
                  episodeNumber: target.episodeNumber!,
                  title: '',
                );
        plan(
          path: target.nfoPath,
          bytes: VideoNfoBuilder.buildEpisode(
            episode,
            primaryProvider: metadata.provider,
          ),
          policy: policy,
          kind: 'nfo',
          episodeId: persisted
              .episodeIds[(episode.seasonNumber, episode.episodeNumber)],
        );
      }
    }

    final Map<String, VideoMetadataDownloadedAsset> downloads =
        <String, VideoMetadataDownloadedAsset>{};
    if (settings.writeImages) {
      // 规范库可以保留多张 backdrop 供应用内轮播，但 MoviePilot/Kodi 的
      // sidecar 命名对同一层级和图种只有一个稳定槽位。只把排序后的首选图
      // 写到媒体目录，避免后续候选覆盖首选图或因扩展名不同留下冲突副本。
      final Set<String> plannedImageSlots = <String>{};
      for (final VideoMetadataImage image in _allImages(metadata)) {
        cancellationToken.throwIfCancelled();
        final List<VideoSidecarTarget> targets =
            _targetsForImage(layout, image);
        if (targets.isEmpty) continue;
        final String imageSlot = '${image.seasonNumber ?? 'work'}:'
            '${image.episodeNumber ?? 'work'}:${image.kind.name}';
        if (!plannedImageSlots.add(imageSlot)) continue;
        VideoMetadataDownloadedAsset asset;
        try {
          asset = downloads[image.url] ??=
              await assetDownloader.download(image.url);
        } catch (error) {
          errors.add(SourceScrapeIssue(
            workTitle: localWork.title,
            message: '图片下载失败：$error',
            path: image.url,
          ));
          continue;
        }
        for (final VideoSidecarTarget target in targets) {
          final int? seasonId = image.seasonNumber == null
              ? null
              : persisted.seasonIds[image.seasonNumber!];
          final int? episodeId = image.episodeNumber == null
              ? null
              : persisted
                  .episodeIds[(image.seasonNumber ?? 1, image.episodeNumber!)];
          for (final String path in target.imagePaths(
            image.kind,
            extension: asset.extension,
          )) {
            plan(
              path: path,
              bytes: asset.bytes,
              policy: settings.imagePolicy,
              kind: image.kind.name,
              seasonId: seasonId,
              episodeId: episodeId,
              remoteUrl: image.url,
            );
          }
        }
      }
    }

    cancellationToken.throwIfCancelled();
    final SidecarWriteSummary summary = await writer.writeAll(
      planned.values.map((_PlannedArtifact value) => value.request),
    );
    int nfoWritten = 0;
    int imagesWritten = 0;
    int protected = 0;
    final Map<String, String> localPathByUrl = <String, String>{};
    for (final SidecarWriteResult result in summary.results) {
      final _PlannedArtifact? artifact = planned[_pathKey(result.targetPath)];
      final VideoSidecarArtifactContext? context = artifact?.context;
      if (result.didWrite) {
        if (context?.artifactKind == 'nfo') {
          nfoWritten++;
        } else {
          imagesWritten++;
        }
      }
      if (result.status == SidecarWriteStatus.protectedExisting ||
          result.status == SidecarWriteStatus.protectedModified ||
          result.status == SidecarWriteStatus.skippedExisting) {
        protected++;
      }
      if ((result.didWrite || result.status == SidecarWriteStatus.unchanged) &&
          context?.remoteUrl != null) {
        localPathByUrl.putIfAbsent(
          context!.remoteUrl!,
          () => result.targetPath,
        );
      }
      if (result.isFailure || result.artifactStoreError != null) {
        // 所有权登记失败时把真实异常带出去：只有「文件已写入，但所有权记录失败」
        // 一句话，用户和我们都无从判断是 context 没登记、UNIQUE 撞了还是 DB 忙
        // （2026-09-08 用户 Takagi-san Cover Song Collection 三条报错就卡在这里）。
        final Object? detail = result.artifactStoreError ?? result.error;
        final String base =
            result.message ?? result.error?.toString() ?? 'sidecar 写入失败';
        errors.add(SourceScrapeIssue(
          workTitle: localWork.title,
          path: result.targetPath,
          message: detail == null || base.contains(detail.toString())
              ? base
              : '$base：$detail',
        ));
      }
    }
    if (localPathByUrl.isNotEmpty) {
      await _store.updateCanonicalImagePaths(
        persisted: persisted,
        metadata: metadata,
        localPathByRemoteUrl: localPathByUrl,
      );
      await _writeLegacyImages(
        localWork,
        metadata,
        localPathByUrl,
        episodeOverrides,
      );
    }
    return _SidecarOutcome(
      nfoWritten: nfoWritten,
      imagesWritten: imagesWritten,
      protectedArtifacts: protected,
      unchangedArtifacts: summary.unchangedCount,
      warnings: warnings,
      errors: errors,
    );
  }

  Future<void> _writeLegacyImages(
    VideoSourceScrapeWork localWork,
    VideoMetadataWork metadata,
    Map<String, String> localPathByUrl,
    Map<String, (int, int)> episodeOverrides,
  ) async {
    final VideoMetadataImage? cover = metadata.images
        .where((VideoMetadataImage image) =>
            image.kind == VideoMetadataImageKind.cover &&
            localPathByUrl.containsKey(image.url))
        .firstOrNull;
    if (cover != null) {
      final String coverPath = localPathByUrl[cover.url]!;
      final DatabaseSidecarGeneratedArtifactChecker generated =
          DatabaseSidecarGeneratedArtifactChecker(database);
      await VideoCoverMutationGate.runExclusive(() async {
        if (localWork.collection case final MediaCollectionRow collection) {
          final MediaCollectionRow? current =
              await database.getMediaCollectionById(collection.id);
          if (current != null &&
              (current.coverPath == null ||
                  await generated.isUnmodifiedGeneratedArtifact(
                    current.coverPath!,
                  ))) {
            await database.updateMediaCollectionCoverPath(
              collection.id,
              coverPath,
            );
          }
        } else {
          final VideoBookRow planned = localWork.members.single;
          final VideoBookRow? current =
              await database.getVideoBookByBookUid(planned.bookUid);
          if (current != null &&
              (current.coverPath == null ||
                  await generated.isUnmodifiedGeneratedArtifact(
                    current.coverPath!,
                  ))) {
            await database.updateVideoBookCover(planned.bookUid, coverPath);
          }
        }
      });
    }

    final List<MediaImagesCompanion> workImages = _legacyImageRows(
      metadata.images,
      localPathByUrl,
      collectionId: localWork.collection?.id,
      bookUid: localWork.collection == null
          ? localWork.members.single.bookUid
          : null,
    );
    if (workImages.isNotEmpty) {
      if (localWork.collection case final MediaCollectionRow collection) {
        await database.replaceMediaImagesForCollection(
            collection.id, workImages);
      } else {
        await database.replaceMediaImagesForBook(
          localWork.members.single.bookUid,
          workImages,
        );
      }
    }
    for (final VideoBookRow book in localWork.members) {
      final (int, int)? key = localEpisodeKeyFor(book, episodeOverrides);
      if (key == null) continue;
      final VideoMetadataEpisode? episode = _episode(metadata, key.$1, key.$2);
      if (episode == null) continue;
      final List<MediaImagesCompanion> rows = _legacyImageRows(
        episode.images,
        localPathByUrl,
        bookUid: book.bookUid,
      );
      if (rows.isNotEmpty) {
        await database.replaceMediaImagesForBook(book.bookUid, rows);
      }
    }
  }

  static List<MediaImagesCompanion> _legacyImageRows(
    Iterable<VideoMetadataImage> images,
    Map<String, String> localPathByUrl, {
    int? collectionId,
    String? bookUid,
  }) {
    final Map<String, int> positions = <String, int>{};
    final List<MediaImagesCompanion> result = <MediaImagesCompanion>[];
    for (final VideoMetadataImage image in images) {
      final String? path = localPathByUrl[image.url];
      if (path == null || image.kind == VideoMetadataImageKind.cover) continue;
      final MediaImageKind? kind = switch (image.kind) {
        VideoMetadataImageKind.backdrop => MediaImageKind.backdrop,
        VideoMetadataImageKind.logo => MediaImageKind.logo,
        VideoMetadataImageKind.thumb ||
        VideoMetadataImageKind.landscape =>
          MediaImageKind.titleCard,
        _ => null,
      };
      if (kind == null) continue;
      final int position = positions.update(
        kind.dbValue,
        (int value) => value + 1,
        ifAbsent: () => 0,
      );
      if (kind != MediaImageKind.backdrop && position > 0) continue;
      result.add(MediaImagesCompanion.insert(
        collectionId: Value<int?>(collectionId),
        bookUid: Value<String?>(bookUid),
        kind: kind.dbValue,
        position: Value<int>(position),
        path: path,
        sourceUrl: Value<String?>(image.url),
      ));
    }
    return result;
  }

  static List<VideoSidecarTarget> _targetsForImage(
    VideoSidecarLayout layout,
    VideoMetadataImage image,
  ) {
    if (image.episodeNumber != null) {
      return layout.episodes
          .where((VideoSidecarTarget target) =>
              target.seasonNumber == (image.seasonNumber ?? 1) &&
              target.episodeNumber == image.episodeNumber)
          .toList();
    }
    if (image.seasonNumber != null) {
      return layout.seasons
          .where((VideoSidecarTarget target) =>
              target.seasonNumber == image.seasonNumber)
          .toList();
    }
    return layout.work == null
        ? const <VideoSidecarTarget>[]
        : <VideoSidecarTarget>[layout.work!];
  }

  static Iterable<VideoMetadataImage> _allImages(
    VideoMetadataWork work,
  ) sync* {
    yield* work.images;
    for (final VideoMetadataSeason season in work.seasons) {
      yield* season.images;
      for (final VideoMetadataEpisode episode in season.episodes) {
        yield* episode.images;
      }
    }
  }

  static VideoMetadataEpisode? _episode(
    VideoMetadataWork work,
    int seasonNumber,
    int episodeNumber,
  ) {
    for (final VideoMetadataSeason season in work.seasons) {
      if (season.seasonNumber != seasonNumber) continue;
      for (final VideoMetadataEpisode episode in season.episodes) {
        if (episode.episodeNumber == episodeNumber) return episode;
      }
    }
    return null;
  }

  /// 歧义候选交给 AI 选唯一命中；回 null 表示「不采用」，调用方照旧走人工确认。
  ///
  /// 采用条件：注入了 [aiIdentityDecider]、它给出了候选集合内的 key、且置信度
  /// 达到 [kAiVideoIdentityAutoAcceptConfidence]。采用时往 [warnings] 记一条
  /// `ai:matched …` 标记（见 `video_scrape_ai_identity_note.dart`），随运行记录
  /// 落库，UI 据此显示「AI 判定 · 置信度 N%」。任何异常都吞掉并记诊断日志。
  Future<VideoSourceScrapeConfirmationCandidate?> _selectCandidateWithAi({
    required VideoSourceScrapeWork localWork,
    required List<String> localTitles,
    required int? seasonNumber,
    required int? episodeCount,
    required int? year,
    required List<VideoSourceScrapeConfirmationCandidate> options,
    required List<SourceScrapeIssue> warnings,
  }) async {
    final AiVideoIdentityDecider? decider = aiIdentityDecider;
    if (decider == null) return null;
    final int? runId = _activeRunId;
    if (runId != null && _aiIdentityFailedRunId == runId) return null;
    final AiVideoIdentityQuery query = AiVideoIdentityQuery(
      localTitles: localTitles,
      season: seasonNumber,
      episodeCount: episodeCount,
      year: year,
      sampleFileNames: <String>[
        for (final VideoBookRow member in localWork.members)
          p.basename(member.videoPath),
      ],
      candidates: <AiVideoIdentityCandidate>[
        for (final VideoSourceScrapeConfirmationCandidate option in options)
          AiVideoIdentityCandidate(
            key: _aiCandidateKey(option),
            titles: _aiCandidateTitles(option.work),
            mediaKind: option.lookup.mediaKind,
            year: option.work.year,
            episodeCount: option.work.episodeCount,
            synopsis: option.work.plot,
          ),
      ],
      locale: _locale,
    );
    final String cacheKey = query.cacheKey;
    final AiVideoIdentityDecision? decision;
    if (_aiIdentityCache.containsKey(cacheKey)) {
      decision = _aiIdentityCache[cacheKey];
    } else {
      AiVideoIdentityDecision? fresh;
      try {
        fresh = await decider(query);
      } catch (_) {
        // AI 故障只影响「要不要自动收敛」，不影响刮削结论：本趟余下作品跳过 AI，
        // 本条照旧进人工确认 / 待确认。诊断日志由 app 侧的决策器自己记——引擎包
        // 会被编成服务端，不依赖 ErrorLogService。
        if (runId != null) _aiIdentityFailedRunId = runId;
        return null;
      }
      // decider 回 null 表示没指派提供商，这种「没问」不缓存：用户随后在设置里
      // 指派了提供商，同一批候选下次就该真的问一次。
      if (fresh == null) return null;
      decision = fresh;
      _aiIdentityCache[cacheKey] = fresh;
    }
    if (decision == null || !decision.isAutoAcceptable) return null;
    final String key = decision.key!;
    for (final VideoSourceScrapeConfirmationCandidate option in options) {
      if (_aiCandidateKey(option) != key) continue;
      warnings.add(SourceScrapeIssue(
        workTitle: localWork.title,
        message: encodeVideoScrapeAiIdentityNote(decision),
      ));
      return option;
    }
    return null;
  }

  /// 候选给 AI 的稳定键，与 resolver 合并候选时的去重键同形（provider:externalId）。
  static String _aiCandidateKey(
    VideoSourceScrapeConfirmationCandidate candidate,
  ) =>
      '${candidate.lookup.provider.name}:${candidate.lookup.externalId}';

  /// 候选的各语言标题：主标题 + 原名 + 别名（去空去重由 [AiVideoIdentityCandidate] 做）。
  static List<String> _aiCandidateTitles(VideoMetadataWork work) => <String>[
        work.title,
        if (work.originalTitle != null) work.originalTitle!,
        ...work.aliases,
      ];

  static List<String> _titleCandidates(
    VideoSourceScrapeWork work,
    VideoNameInfo parsed,
  ) =>
      videoScrapeTitleCandidates(
        workTitle: work.title,
        parsedSeries: parsed.series,
        videoPath: work.members.first.videoPath,
      );

  /// 识别词给每个成员算出的集号偏移（0 不入表）。词表空时恒为空表。
  Map<String, int> _identifierEpisodeOffsets(VideoSourceScrapeWork work) {
    final ScrapeIdentifierWords words = config.identifierWords;
    if (words.isEmpty) return const <String, int>{};
    final Map<String, int> offsets = <String, int>{};
    for (final VideoBookRow member in work.members) {
      final int offset =
          words.apply(p.basename(member.videoPath)).episodeOffset;
      if (offset != 0) offsets[member.bookUid] = offset;
    }
    return offsets;
  }

  /// 把识别词偏移折成 `bookUid → (季, 集)` 覆盖，语义与 [localEpisodeKeyFor]
  /// 的文件名解析对齐（季缺省 1）。解不出集号或偏移越界的成员不写覆盖。
  static Map<String, (int, int)> _identifierEpisodeOverrides(
    VideoSourceScrapeWork work,
    Map<String, int> offsets,
  ) {
    if (offsets.isEmpty) return const <String, (int, int)>{};
    final Map<String, (int, int)> overrides = <String, (int, int)>{};
    for (final VideoBookRow member in work.members) {
      final int offset = offsets[member.bookUid] ?? 0;
      if (offset == 0) continue;
      final VideoNameInfo parsed =
          parseVideoFilename(p.basename(member.videoPath));
      final ({int? season, int? episode}) shifted =
          _shiftedEpisodeKey(parsed, offset);
      final int? episode = shifted.episode;
      if (episode == null || episode == parsed.episode) continue;
      overrides[member.bookUid] = (shifted.season ?? 1, episode);
    }
    return overrides;
  }

  /// 对解析结果套用集号偏移；越界（≤ 0 或 > 9999）时保留原编号。
  static ({int? season, int? episode}) _shiftedEpisodeKey(
    VideoNameInfo parsed,
    int offset,
  ) {
    final int? episode = parsed.episode;
    if (episode == null || offset == 0) {
      return (season: parsed.season, episode: episode);
    }
    final int shifted = episode + offset;
    return (
      season: parsed.season,
      episode: shifted > 0 && shifted <= 9999 ? shifted : episode,
    );
  }

  static int? _parsedSeason(
    VideoSourceScrapeWork work,
    VideoNameInfo filename,
  ) {
    if (filename.season != null) return filename.season;
    final String path = work.members.first.videoPath;
    for (final String directory in <String>[
      p.basename(p.dirname(path)),
      p.basename(p.dirname(p.dirname(path))),
    ]) {
      final int? season = FilenameParser.parse(directory).season;
      if (season != null) return season;
    }
    return null;
  }

  static int? _parsedYear(VideoSourceScrapeWork work) {
    final List<String> candidates = <String>[
      work.title,
      for (final VideoBookRow row in work.members) ...<String>[
        p.basenameWithoutExtension(row.videoPath),
        p.basename(p.dirname(row.videoPath)),
        p.basename(p.dirname(p.dirname(row.videoPath))),
      ],
    ];
    // 年份必须经过仓内唯一的 anitomy 式解析器。直接在整段路径上找 4 位数字会
    // 把 `[1920x1080]` 的 1920 当成年份，随后严格匹配会把真正的 2015 候选拒掉。
    // 逐候选解析还保留了文件名 > 父目录 > 祖父目录的确定优先级。
    for (final String candidate in candidates) {
      final int? year = FilenameParser.parse(candidate).year;
      if (year != null) return year;
    }
    return null;
  }

  static VideoMetadataLookup? _lookupForCandidate(
    VideoMetadataWork work,
    VideoMetadataProviderKind provider,
  ) {
    final VideoMetadataId? id = work.ids
        .where((VideoMetadataId value) =>
            value.type.toLowerCase() == provider.name &&
            value.value.trim().isNotEmpty)
        .firstOrNull;
    return id == null
        ? null
        : VideoMetadataLookup(
            provider: provider,
            externalId: id.value,
            mediaKind: work.kind,
            episodeGroupId: work.episodeGroupId,
          );
  }

  Future<void> _publish(
    int runId,
    VideoSourceScrapeProgressCallback callback,
    VideoSourceScrapeProgress progress, {
    int? totalWorks,
    int? processedWorks,
    int? succeededWorks,
    int? failedWorks,
    int? pendingConfirmations,
    String? currentWorkTitle,
  }) async {
    callback(progress);
    await database.updateVideoSourceScrapeRun(
      runId,
      VideoSourceScrapeRunsCompanion(
        phase: Value<String?>(progress.phase.name),
        totalWorks:
            totalWorks == null ? const Value<int>.absent() : Value(totalWorks),
        processedWorks: processedWorks == null
            ? const Value<int>.absent()
            : Value(processedWorks),
        succeededWorks: succeededWorks == null
            ? const Value<int>.absent()
            : Value(succeededWorks),
        failedWorks: failedWorks == null
            ? const Value<int>.absent()
            : Value(failedWorks),
        pendingConfirmations: pendingConfirmations == null
            ? const Value<int>.absent()
            : Value(pendingConfirmations),
        currentWorkTitle: currentWorkTitle == null
            ? const Value<String?>.absent()
            : Value<String?>(currentWorkTitle),
        updatedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  Future<void> _updateRunCounts(
    int runId, {
    required int processedWorks,
    required int succeededWorks,
    required int failedWorks,
    required int pendingConfirmations,
  }) =>
      database.updateVideoSourceScrapeRun(
        runId,
        VideoSourceScrapeRunsCompanion(
          processedWorks: Value<int>(processedWorks),
          succeededWorks: Value<int>(succeededWorks),
          failedWorks: Value<int>(failedWorks),
          pendingConfirmations: Value<int>(pendingConfirmations),
          updatedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
        ),
      );

  Future<void> _finishRun(
    int runId, {
    required String status,
    required SourceScrapeReport report,
    String? lastError,
  }) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    return database.updateVideoSourceScrapeRun(
      runId,
      VideoSourceScrapeRunsCompanion(
        status: Value<String>(status),
        phase: Value<String?>(status),
        totalWorks: Value<int>(report.totalWorks),
        processedWorks: Value<int>(
          report.succeededWorks +
              report.failedWorks +
              report.pendingConfirmations,
        ),
        succeededWorks: Value<int>(report.succeededWorks),
        failedWorks: Value<int>(report.failedWorks),
        pendingConfirmations: Value<int>(report.pendingConfirmations),
        summaryJson: Value<String?>(_reportJson(report)),
        lastError: Value<String?>(lastError),
        updatedAt: Value<int>(now),
        finishedAt: Value<int?>(now),
      ),
    );
  }

  static String _reportJson(SourceScrapeReport report) =>
      encodeSourceScrapeReport(report);

  @override
  Future<void> markActiveRunInterrupted() async {
    final int? runId = _activeRunId;
    if (runId == null) return;
    _interruptedRunIds.add(runId);
    final int now = DateTime.now().millisecondsSinceEpoch;
    await database.updateVideoSourceScrapeRun(
      runId,
      VideoSourceScrapeRunsCompanion(
        status: const Value<String>('interrupted'),
        phase: const Value<String?>('interrupted'),
        updatedAt: Value<int>(now),
        finishedAt: Value<int?>(now),
      ),
    );
  }

  void close() {
    if (_ownsHashIdentityService) unawaited(hashIdentityService.close());
    if (_ownsRegistry) registry.close();
    if (_ownsAssetDownloader) assetDownloader.close();
    offlineIdentityResolver?.close();
    if (_ownsIdentityMapping) identityMapping?.close();
    if (_ownsEpisodeRelations) episodeRelations?.close();
  }

  static String _pathKey(String value) {
    final String normalized = p.normalize(p.absolute(value));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }
}

/// 作品识别的标题候选，按文件名、父目录、祖父目录的优先级排列。
///
/// MoviePilot MetaInfoPath 会分别解析文件名、父目录和祖父目录后再合并。
/// 原始目录名通常还带字幕组、全集范围、编码等块，直接拿它请求 provider 会
/// 得到零结果；清洗后的标题必须先进入候选，原值仅保留显式 ID 等兼容信息。
///
/// **文件派生**候选（作品标题 / 文件名解析出的系列名）若只是纯集号标签
/// （`01` / `第01集` / `S01E01`：引擎给不出标题却解出了集号），不进 provider：
/// 它们在 MAL/TMDB 上只能搜出一堆类型合格、标题不符的垃圾候选，把整条识别
/// 污染成「待确认」，还白白消耗 Jikan 配额。**目录名**候选不受此限——目录
/// `86` 是用户手写的番名，不是集号。
List<String> videoScrapeTitleCandidates({
  required String workTitle,
  required String parsedSeries,
  required String videoPath,
}) {
  final List<String> fileDerived = <String>[workTitle, parsedSeries];
  final List<String> directoryDerived = <String>[
    _pathSegmentFromEnd(videoPath, 1),
    _pathSegmentFromEnd(videoPath, 2),
  ];
  final List<String> rawValues = <String>[
    for (final String value in fileDerived)
      if (!isEpisodeLabelTitle(value)) value,
    ...directoryDerived,
  ];
  final List<String> values = <String>[
    for (final String value in rawValues) ...<String>[
      FilenameParser.parse(value).title,
      value,
    ],
  ];
  final Set<String> seen = <String>{};
  return <String>[
    for (final String value in values)
      if (value.trim().isNotEmpty && seen.add(value.trim().toLowerCase()))
        value.trim(),
  ];
}

/// 取路径倒数第 [n] 层目录名（n = 1 是直接父目录）；取不到回空串。
///
/// **不能用 `p.basename(p.dirname(...))`**：`package:path` 顶层函数按**当前平台**
/// 的分隔符解析，Linux 上遇到 `D:\Videos\86\01.mkv` 这种 Windows 风格路径会认成
/// 单段，dirname 给出 `'.'`，于是候选里混进一个字面量点 —— 本机 Windows 全绿、
/// CI Linux 红，正是这条平台差异（develop@60e3964a 的单测门）。
///
/// 这里做的只是**文本切分**（从路径里捞目录名当刮削标题候选），与真实文件系统无关，
/// 所以两种分隔符一律接受，与 `video_filename_parser.dart` 里同款切分保持一致。
String _pathSegmentFromEnd(String path, int n) {
  final List<String> segments = path
      .split(RegExp(r'[\\/]+'))
      .where((String segment) => segment.isNotEmpty && segment != '.')
      .toList();
  final int index = segments.length - 1 - n;
  return index >= 0 ? segments[index] : '';
}

/// 把识别词表应用到一组标题候选：改写结果排在最前，原候选保留在后。
///
/// 规则写错时（比如屏蔽词把整个标题吃掉）原候选仍在，识别不会整条归零。
List<String> applyScrapeIdentifierWordsToCandidates(
  List<String> candidates,
  ScrapeIdentifierWords words,
) {
  if (words.isEmpty) return candidates;
  final List<String> rewritten = <String>[];
  for (final String candidate in candidates) {
    final String next = words.apply(candidate).title.trim();
    if (next.isNotEmpty && next != candidate.trim()) rewritten.add(next);
  }
  if (rewritten.isEmpty) return candidates;
  final Set<String> seen = <String>{};
  return <String>[
    for (final String value in <String>[...rewritten, ...candidates])
      if (value.trim().isNotEmpty && seen.add(value.trim().toLowerCase()))
        value.trim(),
  ];
}

/// 一个字符串是否只是集号标签而非作品标题：规则引擎解不出标题、却解出了集号。
/// 四位数（`1917` 这类年份/片名）不算，避免把纯数字片名误杀。
bool isEpisodeLabelTitle(String value) {
  final String trimmed = value.trim();
  if (trimmed.isEmpty) return false;
  if (RegExp(r'\d{4}').hasMatch(trimmed)) return false;
  final ParsedMediaName parsed = FilenameParser.parse(trimmed);
  return parsed.title.trim().isEmpty && parsed.episode != null;
}

class _EffectiveSourceSettings {
  const _EffectiveSourceSettings({
    required this.enabled,
    required this.provider,
    required this.locale,
    required this.writeNfo,
    required this.writeImages,
    required this.nfoPolicy,
    required this.imagePolicy,
    required this.allowExternalOverwrite,
  });

  factory _EffectiveSourceSettings.from(
    VideoSourceScrapeSettingRow? row,
    VideoSourceScrapeGlobalConfig config, {
    required bool allowProtectedOverwrite,
    VideoMetadataProviderKind primaryProvider =
        kDefaultVideoMetadataPrimaryProvider,
  }) {
    return _EffectiveSourceSettings(
      enabled: row?.enabled ?? true,
      // 来源级 provider_override：anidb / mal / tmdb 覆盖全局主源；NULL 或历史值
      // （bangumi / douban / anilist）回落全局默认。
      provider: parseSelectableVideoMetadataProvider(row?.providerOverride) ??
          primaryProvider,
      // 来源级 metadata_locale：NULL / 全空白 = 跟随全局。
      locale: switch (row?.metadataLocale?.trim()) {
        final String value when value.isNotEmpty => value,
        _ => config.locale,
      },
      writeNfo: row?.writeNfo ?? true,
      writeImages: row?.writeImages ?? true,
      nfoPolicy: _policy(row?.nfoPolicy),
      imagePolicy: _policy(row?.imagePolicy),
      allowExternalOverwrite:
          (row?.allowExternalOverwrite ?? false) && allowProtectedOverwrite,
    );
  }

  final bool enabled;
  final VideoMetadataProviderKind provider;

  /// 本来源刮削用的资料语言（BCP-47）；已经过「空 → 全局」归一。
  final String locale;
  final bool writeNfo;
  final bool writeImages;
  final SidecarWritePolicy nfoPolicy;
  final SidecarWritePolicy imagePolicy;
  final bool allowExternalOverwrite;

  static SidecarWritePolicy _policy(String? value) =>
      SidecarWritePolicy.values.asNameMap()[value] ??
      SidecarWritePolicy.missingOnly;
}

/// [_expandMalSeasons] 的结果：主季在剧内的季号、需要追加的其它季、成员集号覆盖。
class _SeasonExpansion {
  const _SeasonExpansion({
    this.primarySeasonNumber,
    this.extraSeasons = const <VideoMetadataSeason>[],
    this.extraCredits = const <VideoMetadataCredit>[],
    this.episodeOverrides = const <String, (int, int)>{},
    this.complete = true,
    this.tmdbSlices = const <int, TmdbSeasonSlice>{},
  });

  final int? primarySeasonNumber;
  final List<VideoMetadataSeason> extraSeasons;

  /// 其它 cour 条目的人物关系，按主条目的表合并（同人同角色去重、只补空）。
  final List<VideoMetadataCredit> extraCredits;
  final Map<String, (int, int)> episodeOverrides;

  /// false = 有季 / 集没能对齐或拉取失败，季集记录不能当权威删除依据。
  final bool complete;

  /// 卡片季号 → 该 MAL cour 在 TMDB 剧里的位置（映射表显式给的 `season.tmdb` /
  /// `episode_offset.tmdb`），供 MAL 缺集时按切片从 TMDB 补分集。
  final Map<int, TmdbSeasonSlice> tmdbSlices;
}

/// [_applyAnidbEpisodeLinks] 的结果：成员 (季, 集) 覆盖 + 链接成功成员的交叉引用
/// （带评级）。
/// 按 AniDB 作品拆出来的一个子单元：单文件电影 `book:` 单元或新建合集的剧集
/// 单元，外加映射表给出的已确认身份（没有就让它自己识别）。
class _SplitWork {
  const _SplitWork({
    required this.work,
    required this.lookup,
    required this.animeId,
    required this.kind,
  });
  final VideoSourceScrapeWork work;
  final VideoMetadataLookup? lookup;
  final int animeId;
  final VideoMetadataMediaKind kind;
}

/// [_splitByAnidbWork] 决定形态后、动库前的一组成员。
class _PlannedSplitGroup {
  const _PlannedSplitGroup({
    required this.animeId,
    required this.members,
    required this.title,
    required this.kind,
    required this.lookup,
  });
  final int animeId;
  final List<VideoBookRow> members;
  final String title;
  final VideoMetadataMediaKind kind;
  final VideoMetadataLookup? lookup;
}

class _AppliedAnidbLinks {
  const _AppliedAnidbLinks(this.overrides, this.xrefs, this.additional);
  final Map<String, (int, int)> overrides;
  final Map<String, AnidbEpisodeXref> xrefs;

  /// 一文件多集的额外绑定（bookUid → 额外卡片键 → 该集身份）。
  final AnidbAdditionalEpisodeBindings additional;
}

/// [_anidbLinkSources] 的结果：正片来源集（键 = AniDB 集号）与 `S` 型特典来源集
/// （键 = 特典序号）。
class _AnidbLinkSources {
  const _AnidbLinkSources({required this.regular, required this.specials});
  final List<TmdbEpisodeMatchSource> regular;
  final List<TmdbEpisodeMatchSource> specials;
  bool get isNotEmpty => regular.isNotEmpty || specials.isNotEmpty;
}

/// [_resolveMappedSeasonHit] 的结果：[index] 为 null 表示映射表认识这一季但
/// 集号落不进任何条目。
class _MappedSeasonHit {
  const _MappedSeasonHit({required this.index, required this.episode});
  final int? index;
  final int episode;
}

class _ResolvedWork {
  const _ResolvedWork({
    this.metadata,
    this.pending = false,
    this.reason,
    this.status,
    this.seasonEpisodesAuthoritative = false,
    this.episodeOverrides = const <String, (int, int)>{},
    this.anidbEpisodeXrefs = const <String, AnidbEpisodeXref>{},
    this.anidbAdditionalBindings =
        const <String, Map<(int, int), AnidbEpisodeXref>>{},
    this.splitInto = const <_SplitWork>[],
    this.userVerifiedBooks = const <String>{},
  });

  final VideoMetadataWork? metadata;

  /// 用户手动钉死季集（UserVerified）的成员 `bookUid`：落库时先占位，同键的
  /// 自动链接 / 文件名解析成员让位。
  final Set<String> userVerifiedBooks;

  /// `pending` 的一种特殊形态：成员分属不同 AniDB 作品，已拆成这些子单元
  /// （电影 / 新合集的剧集），调用方把它们接着刮而不是记一条待确认。
  final List<_SplitWork> splitInto;

  /// 一文件多集：成员 `bookUid` → 额外卡片 (季, 集) → 该集 AniDB 身份。
  final AnidbAdditionalEpisodeBindings anidbAdditionalBindings;

  /// 成员 `bookUid` → 本地 (季, 集)：多季合集逐季映射 / 绝对集号重定向的结果，
  /// 入库、sidecar、旧投影三处共用。
  final Map<String, (int, int)> episodeOverrides;

  /// 成员 `bookUid` → AniDB 集身份（+ TMDB 链接评级），随绑定写到分集行。
  final Map<String, AnidbEpisodeXref> anidbEpisodeXrefs;
  final bool pending;
  final String? reason;

  /// 失败分类。以前只往上传一个英文 `reason` 字符串，UI 因此既分不清「源没配」
  /// 和「没匹配上」，也无法把文案翻成中文；这里把 resolver 的结构化状态保留下来。
  final VideoMetadataResolutionStatus? status;
  final bool seasonEpisodesAuthoritative;
}

/// 把 resolver 的结构化失败状态翻成用户能看懂、能照着做的中文说明。
///
/// [fallback] 是 resolver 的英文诊断串，只在状态缺失时兜底。
String describeVideoScrapeFailure(
  VideoMetadataResolutionStatus? status,
  String? fallback,
) =>
    switch (status) {
      VideoMetadataResolutionStatus.providerUnavailable =>
        '视频资料源不可用：请检查 MAL/Jikan 网络及 TMDB API 配置。${fallback == null ? '' : ' $fallback'}',
      VideoMetadataResolutionStatus.notFound => '没有匹配到作品：标题、类型、年份或季号都没通过严格校验。'
          '可以改文件名/目录名，或在文件名里写明 mal=/tmdb:tv=/tmdb:movie= 等明确身份。',
      VideoMetadataResolutionStatus.ambiguous =>
        '匹配结果存在歧义，需要人工确认${fallback == null ? '' : '：$fallback'}',
      VideoMetadataResolutionStatus.matched ||
      null =>
        fallback ?? '没有找到严格匹配的作品',
    };

class _HashWorkEvidence {
  const _HashWorkEvidence(
      {this.animeId,
      this.malId,
      this.mappedMalIds = const <int>{},
      this.titles = const <String>[],
      this.conflicting = false,
      this.identities = const <String, AnidbFileIdentity>{}});

  /// 成员 `bookUid` → 该文件的 AniDB 身份（集号 + 三语集标题），供 Shoko 式
  /// 「集标题 → TMDB 集」核对用。
  final Map<String, AnidbFileIdentity> identities;

  /// 全部成员一致指向的 AniDB 作品；成员分属不同作品时为 null 且 [conflicting]。
  final int? animeId;

  /// anime-lists 唯一映射到的 MAL id；映射缺失或一对多时为 null。
  final int? malId;

  /// anime-lists 给出的全部 MAL 候选（一对多时 >1，供候选确认）。
  final Set<int> mappedMalIds;
  final List<String> titles;
  final bool conflicting;
}

class _HydratedWork {
  const _HydratedWork({required this.metadata, required this.complete});

  final VideoMetadataWork metadata;
  final bool complete;
}

class _TmdbSupplementResult {
  const _TmdbSupplementResult({this.metadata});

  final VideoMetadataWork? metadata;
}

class _PlannedArtifact {
  const _PlannedArtifact({required this.request, required this.context});

  final SidecarWriteRequest request;
  final VideoSidecarArtifactContext context;
}

class _SidecarOutcome {
  const _SidecarOutcome({
    this.nfoWritten = 0,
    this.imagesWritten = 0,
    this.protectedArtifacts = 0,
    this.unchangedArtifacts = 0,
    this.warnings = const <SourceScrapeIssue>[],
    this.errors = const <SourceScrapeIssue>[],
  });

  final int nfoWritten;
  final int imagesWritten;
  final int protectedArtifacts;
  final int unchangedArtifacts;
  final List<SourceScrapeIssue> warnings;
  final List<SourceScrapeIssue> errors;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final Iterator<T> iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}

/// 「一个作品刚刮完」的事实：本地是哪些视频 + 刮出来的规范身份。
///
/// 刻意只带这两样：消费方要什么（补字幕 / 推送通知 / 统计）自己从这两个对象里
/// 取，协调器不预先替它们裁剪。
class VideoScrapedWorkNotice {
  const VideoScrapedWorkNotice({required this.work, required this.metadata});

  /// 本地作品（`work.members` 是这次涉及的 `VideoBookRow`，可能多集）。
  final VideoSourceScrapeWork work;

  /// 刮出来的规范元数据（含 ids / seasons / episodes / runtimeMinutes）。
  final VideoMetadataWork metadata;
}
