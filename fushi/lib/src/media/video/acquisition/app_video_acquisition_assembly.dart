/// 「AI 下视频」的 app 侧组合根：把 [VideoAcquisitionService] 的端口接到本机的发现
/// 源、资源搜索、下载管线、订阅与偏好上。
///
/// 两个调用方共用这一份：首页的对话页入口（本机执行），以及互联 host 的助手会话
/// （手机把一句话交给电脑，电脑用它**自己的** AI 指派与下载管线办）。前置检查（AI
/// 没指派 / 后端没起 / 没有受管来源）各自在调用方做——首页弹引导，host 回能力位
/// 短码——这里只装配。
library;

import 'package:flutter/foundation.dart';
import 'package:fushi/src/ai/ai_video_acquisition_assistant.dart';
import 'package:fushi/src/ai/ai_video_franchise_assistant.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_service.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_service.dart';
import 'package:fushi/src/media/video/download/video_discovery_selection.dart';
import 'package:fushi/src/media/video/download/video_discovery_submit.dart';
import 'package:fushi/src/media/video/scraper/tmdb_default_key.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/sync/app_assistant_host.dart';
import 'package:fushi_engine/sync/assistant/host_assistant.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_download_backend_identity.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi_engine/media/video/download/video_download_subtitle_language.dart';
import 'package:fushi_engine/media/video/download/video_library_presence.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';

/// 发现 / 刮削的全局配置（TMDB key 解析 + 资料语言）。首页缓存的发现控制器与 host
/// 会话自建的发现服务共用这一份判据。
VideoSourceScrapeGlobalConfig videoDiscoveryScrapeConfig(
  PreferencesRepository prefs, {
  required String uiLocaleTag,
}) {
  final String configuredTmdbKey =
      prefs.getPref(kVideoScraperTmdbApiKeyPref, defaultValue: '') as String;
  return VideoSourceScrapeGlobalConfig.fromPreferences(
    prefs,
    resolvedTmdbApiKey: resolveTmdbApiKey(configuredTmdbKey),
    uiLocaleTag: uiLocaleTag,
  );
}

/// 发现条目的身份与一对 (provider, externalId) 是否是同一部作品。
bool videoDiscoveryIdentityMatches(
  VideoMediaReference reference,
  String? provider,
  String? externalId,
) {
  final String normalizedProvider = provider?.trim().toLowerCase() ?? '';
  final String normalizedId = externalId?.trim().toLowerCase() ?? '';
  if (normalizedProvider.isEmpty || normalizedId.isEmpty) return false;
  if (normalizedProvider == reference.providerId.trim().toLowerCase() &&
      normalizedId == reference.mediaId.trim().toLowerCase()) {
    return true;
  }
  return switch (normalizedProvider) {
    'tmdb' => normalizedId == reference.tmdbId?.toString(),
    'anilist' => normalizedId == reference.anilistId?.toString(),
    'bangumi' => normalizedId == reference.bangumiId?.toString(),
    'imdb' => normalizedId == reference.imdbId?.trim().toLowerCase(),
    'tvdb' => normalizedId == reference.tvdbId?.toString(),
    _ => reference.externalIds.entries.any(
      (MapEntry<String, String> entry) =>
          entry.key.trim().toLowerCase() == normalizedProvider &&
          entry.value.trim().toLowerCase() == normalizedId,
    ),
  };
}

/// 本机上与这部作品同一身份的订阅（启用与否都算）。
Future<List<VideoDownloadSubscriptionRow>> matchingVideoDiscoverySubscriptions(
  FushiDatabase database,
  VideoMediaReference reference,
) async => (await database.getVideoDownloadSubscriptions())
    .where(
      (VideoDownloadSubscriptionRow row) => videoDiscoveryIdentityMatches(
        reference,
        row.metadataProvider,
        row.externalId,
      ),
    )
    .toList(growable: false);

/// 「这部作品在不在库」：按 provider:mediaId 与全部跨源 id 逐对查
/// [resolveVideoLibraryPresence]（单身份语义），首个命中即返回；都不命中回第一次
/// 的空答案（非 null，让对话层知道「查过了、没有」）。
Future<VideoLibraryPresence?> resolveAiAcquisitionPresence(
  FushiDatabase database,
  VideoMediaReference reference,
) async {
  final List<(String, String)> identities = <(String, String)>[
    (reference.providerId, reference.mediaId),
    for (final MapEntry<String, String> entry in reference.externalIds.entries)
      (entry.key, entry.value),
  ];
  VideoLibraryPresence? first;
  for (final (String provider, String externalId) in identities) {
    final VideoLibraryPresence presence = await resolveVideoLibraryPresence(
      database,
      metadataProvider: provider,
      externalId: externalId,
      mediaKind: reference.mediaKind,
    );
    if (presence.inLibrary || presence.managedEpisodeKeys.isNotEmpty) {
      return presence;
    }
    first ??= presence;
  }
  return first;
}

/// 组装一个本机执行的 [VideoAcquisitionService]。[locale] 是**说话那个人**的界面
/// 语言（本机 = 本机语言；互联代办 = 手机的语言），AI 解析提示词按它写。
VideoAcquisitionService createAppVideoAcquisitionService({
  required AppModel appModel,
  required Future<ProviderBatchResult<VideoDiscoveryPage>> Function(
    VideoDiscoveryRequest request,
  )
  searchWorks,
  required VideoDiscoveryService? discoveryService,
  required VideoResourceRegistry registry,
  required VideoDownloadPipelineService pipeline,
  required List<MediaSourceRow> sources,
  required String locale,
}) {
  final PreferencesRepository prefs = appModel.prefsRepo;
  final int? defaultSourceId = prefs.videoDownloadTargetSourceId;
  MediaSourceRow sourceById(int id) =>
      sources.firstWhere((MediaSourceRow source) => source.id == id);
  return VideoAcquisitionService(
    defaults: VideoAcquisitionDefaults(
      qualityPref: prefs.aiVideoDownloadQuality,
      sourcePref: VideoAcquisitionSourcePref.parse(prefs.aiVideoDownloadSource),
      bitratePref: VideoAcquisitionBitratePref.parse(
        prefs.aiVideoDownloadBitrate,
      ),
      subtitleLanguagePref: prefs.aiVideoDownloadSubtitleLanguage,
      sources: <VideoAcquisitionSource>[
        for (final MediaSourceRow source in sources)
          VideoAcquisitionSource(id: source.id, label: source.label),
      ],
      defaultSourceId: (defaultSourceId ?? 0) == 0 ? null : defaultSourceId,
      locale: locale,
      skipExtras: prefs.videoDownloadSkipExtras,
    ),
    ports: VideoAcquisitionPorts(
      searchWorks: searchWorks,
      loadDetails: (VideoDiscoveryItem item) async =>
          discoveryService?.loadDetails(item),
      queryPresence: (VideoMediaReference reference) =>
          resolveAiAcquisitionPresence(appModel.database, reference),
      isSubscribed: (VideoMediaReference reference) async =>
          (await matchingVideoDiscoverySubscriptions(
            appModel.database,
            reference,
          )).any((VideoDownloadSubscriptionRow row) => row.enabled),
      searchResources: registry.search,
      // 资料源（TMDB collection + MAL 关联）+ 联网资料补全（维基 → AI 列作品 →
      // 逐部回资料源核对），见 ai_video_franchise_assistant.dart。
      loadFranchise: createPreferencesVideoFranchiseLoader(
        prefs,
        base: (VideoDiscoveryItem item) async =>
            discoveryService?.loadFranchise(item),
        searchWorks: searchWorks,
      ),
      parseIntent: createPreferencesVideoAcquisitionIntentParser(prefs),
      decideIdentity: createPreferencesVideoAcquisitionIdentityDecider(prefs),
      // 所有查询词都搜空时：按原话查联网资料 → AI 抄出正式名 → 再搜一轮。
      resolveAlias: createPreferencesVideoAcquisitionAliasResolver(prefs),
      persistPreference:
          (VideoAcquisitionPreference preference, String value) =>
              switch (preference) {
                VideoAcquisitionPreference.quality =>
                  prefs.setAiVideoDownloadQuality(value),
                VideoAcquisitionPreference.subtitleLanguage =>
                  prefs.setAiVideoDownloadSubtitleLanguage(value),
              },
      // 键与导入落库的合集名同源（videoDownloadSeriesKey），管线字幕阶段按同一把
      // 钥匙读回来。
      setSeriesSubtitleLanguage: (VideoMediaReference reference, String code) =>
          appModel.setJimakuPreferredLanguage(
            videoDownloadSeriesKey(
              title: reference.title,
              year: reference.year,
            ),
            code,
          ),
      submitDownload: (VideoAcquisitionSubmitDownloadEffect effect) async {
        final VideoDownloadBackendTarget target = await appModel
            .currentVideoDownloadBackendTarget();
        final MediaSourceRow source = sourceById(effect.targetSourceId);
        // 串行入队、首条失败直接抛（后端 / 落地问题对整批成立）、后续失败只记数：
        // 与资源搜索页的批量提交同一口径。
        int queued = 0;
        for (int i = 0; i < effect.plan.picks.length; i++) {
          try {
            await enqueueLocalVideoDownload(
              pipeline: pipeline,
              coverUrl: effect.item.posterUrl,
              selection: VideoDiscoveryDownloadSelection(
                media: effect.item.reference,
                resource: effect.plan.picks[i],
                source: source,
                subtitlePolicy: effect.installSubtitles
                    ? VideoDownloadSubtitlePolicy.bestEffort
                    : VideoDownloadSubtitlePolicy.none,
              ),
              target: target,
            );
            queued++;
          } on Object catch (error, stackTrace) {
            if (i == 0) rethrow;
            debugPrint(
              '[ai-acquire] batch enqueue failed: $error\n$stackTrace',
            );
          }
        }
        return queued;
      },
      submitSubscription:
          (VideoAcquisitionSubmitSubscriptionEffect effect) async {
            final VideoDownloadBackendTarget target = await appModel
                .currentVideoDownloadBackendTarget();
            final StrictVideoSubscriptionFilter? filter = effect.plan.filter;
            if (filter == null) {
              throw StateError('subscription plan without a strict filter');
            }
            await createLocalVideoDownloadSubscription(
              database: appModel.database,
              reference: effect.item.reference,
              coverUrl: effect.item.posterUrl,
              selection: VideoDiscoverySubscriptionSelection(
                download: VideoDiscoveryDownloadSelection(
                  media: effect.item.reference,
                  resource: effect.plan.picks.first,
                  source: sourceById(effect.targetSourceId),
                  subtitlePolicy: effect.installSubtitles
                      ? VideoDownloadSubtitlePolicy.bestEffort
                      : VideoDownloadSubtitlePolicy.none,
                ),
                filter: filter,
                startAfterEpisode: effect.plan.startAfterEpisode,
              ),
              target: target,
              checkNow: () async =>
                  appModel.videoDownloadSubscriptionService?.checkNow(),
            );
          },
    ),
  );
}

/// 互联 host 的 AI 助手：能力判断与首页入口同一组门（iOS 合规 / 浏览模块 / AI 指派 /
/// 下载就绪 / 受管来源），缺什么回稳定短码；每场会话自建一份发现服务，会话结束即关。
AppAssistantHost createAppAssistantHost(AppModel appModel) => AppAssistantHost(
  videoAcquireBlocker: () async {
    if (!StoreRestrictedCapability.downloads.isAvailable ||
        !StoreRestrictedCapability.externalDiscovery.isAvailable ||
        !appModel.moduleVisibility.isEnabled(ModuleId.browse)) {
      return kAppAssistantReasonDisabled;
    }
    if (resolveVideoAcquireAiProvider(appModel.prefsRepo) == null) {
      return kAppAssistantReasonNoProvider;
    }
    if (appModel.videoResourceRegistry == null ||
        appModel.videoDownloadPipelineService == null ||
        (await appModel.getManagedVideoDownloadSources()).isEmpty) {
      return kAppAssistantReasonNotReady;
    }
    return null;
  },
  openVideoAcquisition: (String locale) async {
    final VideoResourceRegistry? registry = appModel.videoResourceRegistry;
    final VideoDownloadPipelineService? pipeline =
        appModel.videoDownloadPipelineService;
    final List<MediaSourceRow> sources = await appModel
        .getManagedVideoDownloadSources();
    // 门在 open 之前刚查过；这里再落空只可能是恰好在两步之间被关掉。
    if (registry == null || pipeline == null || sources.isEmpty) {
      throw const HostAssistantUnavailable(kAppAssistantReasonNotReady);
    }
    final String uiLocale = locale.isEmpty
        ? appModel.appLocale.toLanguageTag()
        : locale;
    final VideoDiscoveryService discovery = VideoDiscoveryService.production(
      videoDiscoveryScrapeConfig(appModel.prefsRepo, uiLocaleTag: uiLocale),
    );
    return (
      service: createAppVideoAcquisitionService(
        appModel: appModel,
        searchWorks: discovery.load,
        discoveryService: discovery,
        registry: registry,
        pipeline: pipeline,
        sources: sources,
        locale: uiLocale,
      ),
      release: discovery.close,
    );
  },
);
