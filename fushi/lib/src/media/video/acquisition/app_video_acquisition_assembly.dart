/// 「AI 下视频」的 app 侧组合根：把 [VideoAcquisitionService] 的端口接到本机的发现
/// 源、资源搜索、下载管线、订阅与偏好上。
///
/// 两个调用方共用这一份：首页的对话页入口（本机执行），以及互联 host 的助手会话
/// （手机把一句话交给电脑，电脑用它**自己的** AI 指派与下载管线办）。前置检查（AI
/// 没指派 / 后端没起 / 没有受管来源）各自在调用方做——首页弹引导，host 回能力位
/// 短码——这里只装配。
library;

import 'package:fushi/src/media/video/scraper/tmdb_default_key.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_video_acquisition_assistant.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/acquisition/host_video_acquisition_assembly.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_prefs.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_service.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_service.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/sync/assistant/host_assistant.dart';
import 'package:fushi_engine/sync/assistant/video_acquisition_assistant_host.dart';

// 身份匹配 / 订阅查找 / 在库判定随组合根下沉到引擎（无头服务端共用）；首页仍经
// 本文件拿它们。
export 'package:fushi_engine/media/video/acquisition/host_video_acquisition_assembly.dart'
    show
        matchingVideoDiscoverySubscriptions,
        resolveAiAcquisitionPresence,
        videoDiscoveryIdentityMatches;

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

/// 组装一个本机执行的 [VideoAcquisitionService]。[locale] 是**说话那个人**的界面
/// 语言（本机 = 本机语言；互联代办 = 手机的语言），AI 解析提示词按它写。端口装配
/// 与无头服务端共用引擎的 [createHostVideoAcquisitionService]，这里只接本机偏好。
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
  return createHostVideoAcquisitionService(
    database: appModel.database,
    aiSettings: prefs,
    defaults: readVideoAcquisitionDefaults(
      prefs,
      sources: sources,
      defaultSourceId: prefs.videoDownloadTargetSourceId,
      locale: locale,
    ),
    searchWorks: searchWorks,
    discoveryService: discoveryService,
    registry: registry,
    pipeline: pipeline,
    sources: sources,
    backendTarget: appModel.currentVideoDownloadBackendTarget,
    persistPreference:
        (VideoAcquisitionPreference preference, String value) =>
            switch (preference) {
              VideoAcquisitionPreference.quality =>
                prefs.setAiVideoDownloadQuality(value),
              VideoAcquisitionPreference.subtitleLanguage =>
                prefs.setAiVideoDownloadSubtitleLanguage(value),
            },
    setSeriesSubtitleLanguage: appModel.setJimakuPreferredLanguage,
    checkSubscriptionsNow: () async =>
        appModel.videoDownloadSubscriptionService?.checkNow(),
  );
}

/// 互联 host 的 AI 助手：能力判断与首页入口同一组门（iOS 合规 / 浏览模块 / AI 指派 /
/// 下载就绪 / 受管来源），缺什么回稳定短码；每场会话自建一份发现服务，会话结束即关。
VideoAcquisitionAssistantHost createVideoAcquisitionAssistantHost(AppModel appModel) => VideoAcquisitionAssistantHost(
  videoAcquireBlocker: () async {
    if (!StoreRestrictedCapability.downloads.isAvailable ||
        !StoreRestrictedCapability.externalDiscovery.isAvailable ||
        !appModel.moduleVisibility.isEnabled(ModuleId.browse)) {
      return kHostAssistantReasonDisabled;
    }
    if (resolveVideoAcquireAiProvider(appModel.prefsRepo) == null) {
      return kHostAssistantReasonNoProvider;
    }
    if (appModel.videoResourceRegistry == null ||
        appModel.videoDownloadPipelineService == null ||
        (await appModel.getManagedVideoDownloadSources()).isEmpty) {
      return kHostAssistantReasonNotReady;
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
      throw const HostAssistantUnavailable(kHostAssistantReasonNotReady);
    }
    final String uiLocale = locale.isEmpty
        ? appModel.appLocale.toLanguageTag()
        : locale;
    final VideoDiscoveryService discovery = VideoDiscoveryService.production(
      videoDiscoveryScrapeConfig(appModel.prefsRepo, uiLocaleTag: uiLocale),
      discoveryAvailable:
          StoreRestrictedCapability.externalDiscovery.isAvailable,
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
