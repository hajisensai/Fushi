/// 「AI 下视频」与宿主无关的组合根：把 [VideoAcquisitionService] 的端口接到一台
/// 宿主的发现源、资源搜索、下载管线、订阅与库上。
///
/// app（`app_video_acquisition_assembly.dart`：首页对话页 + 互联 host 助手）与无头
/// 服务端（`fushi_server/lib/src/assistant_host.dart`）共用这一份——两边只在「偏好
/// 从哪读、写回哪、下载后端目标怎么取、订阅检查怎么触发」上不同，那几处是参数。
/// 前置检查（AI 没指派 / 后端没起 / 没有受管来源）各自在调用方做。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/ai/ai_video_acquisition_assistant.dart';
import 'package:fushi_engine/ai/ai_video_franchise_assistant.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_service.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_service.dart';
import 'package:fushi_engine/media/video/download/video_discovery_selection.dart';
import 'package:fushi_engine/media/video/download/video_discovery_submit.dart';
import 'package:fushi_engine/media/video/download/video_download_backend_identity.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi_engine/media/video/download/video_download_subtitle_language.dart';
import 'package:fushi_engine/media/video/download/video_library_presence.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';

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

/// 宿主上与这部作品同一身份的订阅（启用与否都算）。
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

/// 组装一个在本宿主执行的 [VideoAcquisitionService]。
///
/// [defaults] 由宿主从自己的偏好里取（画质 / 片源 / 码率 / 字幕语言 / 默认目标来源 /
/// 跳过特典 / **说话那个人**的界面语言）；[persistPreference] 是「以后默认」勾选的
/// 写回；[setSeriesSubtitleLanguage] 写每系列字幕语言记忆（键已按
/// [videoDownloadSeriesKey] 算好）；[backendTarget] 在提交那一刻现取（后端可用性
/// 延后到提交时判）；[checkSubscriptionsNow] 建订阅后立即检查一次（没装订阅服务
/// 时传 null）。
VideoAcquisitionService createHostVideoAcquisitionService({
  required FushiDatabase database,
  required AiSettingsSource aiSettings,
  required VideoAcquisitionDefaults defaults,
  required Future<ProviderBatchResult<VideoDiscoveryPage>> Function(
    VideoDiscoveryRequest request,
  )
  searchWorks,
  required VideoDiscoveryService? discoveryService,
  required VideoResourceRegistry registry,
  required VideoDownloadPipelineService pipeline,
  required List<MediaSourceRow> sources,
  required Future<VideoDownloadBackendTarget> Function() backendTarget,
  required Future<void> Function(
    VideoAcquisitionPreference preference,
    String value,
  )
  persistPreference,
  required Future<void> Function(String seriesKey, String languageCode)
  setSeriesSubtitleLanguage,
  Future<void> Function()? checkSubscriptionsNow,
}) {
  MediaSourceRow sourceById(int id) =>
      sources.firstWhere((MediaSourceRow source) => source.id == id);
  return VideoAcquisitionService(
    defaults: defaults,
    ports: VideoAcquisitionPorts(
      searchWorks: searchWorks,
      loadDetails: (VideoDiscoveryItem item) async =>
          discoveryService?.loadDetails(item),
      queryPresence: (VideoMediaReference reference) =>
          resolveAiAcquisitionPresence(database, reference),
      isSubscribed: (VideoMediaReference reference) async =>
          (await matchingVideoDiscoverySubscriptions(
            database,
            reference,
          )).any((VideoDownloadSubscriptionRow row) => row.enabled),
      searchResources: registry.search,
      // 资料源（TMDB collection + MAL 关联）+ 联网资料补全（维基 → AI 列作品 →
      // 逐部回资料源核对），见 ai_video_franchise_assistant.dart。
      loadFranchise: createPreferencesVideoFranchiseLoader(
        aiSettings,
        base: (VideoDiscoveryItem item) async =>
            discoveryService?.loadFranchise(item),
        searchWorks: searchWorks,
      ),
      parseIntent: createPreferencesVideoAcquisitionIntentParser(aiSettings),
      decideIdentity: createPreferencesVideoAcquisitionIdentityDecider(
        aiSettings,
      ),
      // 所有查询词都搜空时：按原话查联网资料 → AI 抄出正式名 → 再搜一轮。
      resolveAlias: createPreferencesVideoAcquisitionAliasResolver(aiSettings),
      persistPreference: persistPreference,
      // 键与导入落库的合集名同源（videoDownloadSeriesKey），管线字幕阶段按同一把
      // 钥匙读回来。
      setSeriesSubtitleLanguage: (VideoMediaReference reference, String code) =>
          setSeriesSubtitleLanguage(
            videoDownloadSeriesKey(
              title: reference.title,
              year: reference.year,
            ),
            code,
          ),
      submitDownload: (VideoAcquisitionSubmitDownloadEffect effect) async {
        final VideoDownloadBackendTarget target = await backendTarget();
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
            engineLog.logDiagnostic(
              'VideoAcquisition.enqueue',
              'batch enqueue failed: $error\n$stackTrace',
            );
          }
        }
        return queued;
      },
      submitSubscription:
          (VideoAcquisitionSubmitSubscriptionEffect effect) async {
            final VideoDownloadBackendTarget target = await backendTarget();
            final StrictVideoSubscriptionFilter? filter = effect.plan.filter;
            if (filter == null) {
              throw StateError('subscription plan without a strict filter');
            }
            await createLocalVideoDownloadSubscription(
              database: database,
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
              checkNow: checkSubscriptionsNow,
            );
          },
    ),
  );
}
