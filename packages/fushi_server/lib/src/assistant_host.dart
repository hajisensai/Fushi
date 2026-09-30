/// 服务端的「AI 助手会话」（`/api/assistant`）：手机把「下载执行设备」设成服务端时，
/// AI 下视频整场在这里跑——用**服务端自己的** AI 提供商（配置文件 `ai:` 段）、资源
/// 索引器、下载管线与订阅。
///
/// 会话 / 能力位 / wire 形状全在引擎（[VideoAcquisitionAssistantHost] +
/// [createHostVideoAcquisitionService]，与 app 当 host 时同一份）；这里只接服务端的
/// 端口：AI 读 [ServerAiSettings]，发现走引擎的 [VideoDiscoveryService]（服务端的
/// TMDB key / 资料偏好），入队 / 订阅走 [ServerDownloadHost] 的管线与托管来源。
///
/// 前置门（缺什么回稳定短码，手机据此给出引导）：没配 AI → `no_provider`（**不发任何
/// AI 请求**）；下载后端没起来 / 没有托管来源 → `not_ready`。
library;

import 'dart:convert';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_video_acquisition_assistant.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/acquisition/host_video_acquisition_assembly.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_prefs.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_service.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_service.dart';
import 'package:fushi_engine/media/video/download/video_download_backend_identity.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/sync/assistant/host_assistant.dart';
import 'package:fushi_engine/sync/assistant/video_acquisition_assistant_host.dart';
import 'package:fushi_server/src/config/server_ai_config.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/download_host.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:fushi_server/src/video_scrape_host.dart';

/// 每系列字幕语言记忆的偏好键（与 app `PreferencesRepository.jimakuPreferredLanguages`
/// 同一个键、同一种 JSON map 形状；服务端管线当前没接字幕 registry，先记下不丢）。
const String kServerSeriesSubtitleLanguagesPref = 'jimaku_pref_langs';

/// 服务端会话要用的下载面。生产是 [ServerDownloadHost]，测试注入假管线。
abstract interface class ServerAssistantDownloads {
  VideoDownloadPipelineService? get pipeline;
  VideoResourceRegistry? get registry;
  Future<MediaSourceRow?> downloadSource();
  VideoDownloadBackendTarget backendTarget();
  Future<void> checkSubscriptionsNow();
}

class _DownloadHostAdapter implements ServerAssistantDownloads {
  _DownloadHostAdapter(this._host);

  final ServerDownloadHost _host;

  @override
  VideoDownloadPipelineService? get pipeline => _host.pipeline;
  @override
  VideoResourceRegistry? get registry => _host.registry;
  @override
  Future<MediaSourceRow?> downloadSource() => _host.downloadSource();
  @override
  VideoDownloadBackendTarget backendTarget() => _host.backendTarget();
  @override
  Future<void> checkSubscriptionsNow() => _host.checkSubscriptionsNow();
}

/// 一场会话的发现端口：搜作品 / 拉详情 / 找系列 + 会话结束时释放。
typedef ServerDiscoveryPorts = ({
  Future<ProviderBatchResult<VideoDiscoveryPage>> Function(VideoDiscoveryRequest request) search,
  VideoDiscoveryService? service,
  void Function() release,
});

/// 生产发现：每场会话自建一份引擎发现服务（与 app host 会话同一形状），会话关即关。
/// 资料语言跟**说话那个人**（手机）的界面语言走，偏好表里显式设过资料语言时以偏好
/// 为准（`VideoSourceScrapeGlobalConfig.fromPreferences` 的既有判据）。
ServerDiscoveryPorts productionServerDiscovery({
  required PrefStore prefs,
  required ServerConfig config,
  required String locale,
}) {
  final VideoDiscoveryService service = VideoDiscoveryService.production(
    VideoSourceScrapeGlobalConfig.fromPreferences(
      prefs,
      resolvedTmdbApiKey: resolveServerTmdbApiKey(config, prefs),
      uiLocaleTag: locale.isEmpty ? config.metadataLocale : locale,
    ),
    // 商店合规门只在 iOS app 上存在；服务端没有上架审核面。
    discoveryAvailable: true,
  );
  return (search: service.load, service: service, release: service.close);
}

/// 装配服务端的 [HostAssistantProvider]。[config] 按闭包现取（WebUI 改了 AI 配置
/// 立即生效）；[downloads] 的管线 / 来源每次开会话时现问（后端没起来时报 not_ready）。
VideoAcquisitionAssistantHost createServerAssistantHost({
  required ServerConfig Function() config,
  required ServerPrefs prefs,
  required FushiDatabase db,
  required ServerDownloadHost downloads,
}) =>
    createServerAssistantHostWith(
      config: config,
      prefs: prefs,
      db: db,
      downloads: _DownloadHostAdapter(downloads),
      discovery: (String locale) => productionServerDiscovery(prefs: prefs, config: config(), locale: locale),
    );

/// 同 [createServerAssistantHost]，下载面与发现可注入（测试用）。
VideoAcquisitionAssistantHost createServerAssistantHostWith({
  required ServerConfig Function() config,
  required PrefStore prefs,
  required FushiDatabase db,
  required ServerAssistantDownloads downloads,
  required ServerDiscoveryPorts Function(String locale) discovery,
}) {
  final ServerAiSettings aiSettings = ServerAiSettings(() => config().ai);

  Future<String?> blocker() async {
    // 先判 AI：没指派时连下载面都不必看，更不会走到任何 AI 调用。
    if (resolveVideoAcquireAiProvider(aiSettings) == null) return kHostAssistantReasonNoProvider;
    if (downloads.pipeline == null || downloads.registry == null || await downloads.downloadSource() == null) {
      return kHostAssistantReasonNotReady;
    }
    return null;
  }

  return VideoAcquisitionAssistantHost(
    videoAcquireBlocker: blocker,
    openVideoAcquisition: (String locale) async {
      final VideoDownloadPipelineService? pipeline = downloads.pipeline;
      final VideoResourceRegistry? registry = downloads.registry;
      final MediaSourceRow? source = await downloads.downloadSource();
      // 门在 open 之前刚查过；这里再落空只可能是恰好在两步之间停了下载。
      if (pipeline == null || registry == null || source == null) {
        throw const HostAssistantUnavailable(kHostAssistantReasonNotReady);
      }
      final String speakerLocale = locale.isEmpty ? config().metadataLocale : locale;
      final ServerDiscoveryPorts found = discovery(speakerLocale);
      final List<MediaSourceRow> sources = <MediaSourceRow>[source];
      final VideoAcquisitionService service = createHostVideoAcquisitionService(
        database: db,
        aiSettings: aiSettings,
        defaults: readVideoAcquisitionDefaults(
          prefs,
          sources: sources,
          // 服务端只有一个托管来源（`<documents>/downloads`），直接当默认目标。
          defaultSourceId: source.id,
          locale: speakerLocale,
        ),
        searchWorks: found.search,
        discoveryService: found.service,
        registry: registry,
        pipeline: pipeline,
        sources: sources,
        backendTarget: () async => downloads.backendTarget(),
        persistPreference: (VideoAcquisitionPreference preference, String value) =>
            prefs.setPref(videoAcquisitionPreferenceKey(preference), value),
        setSeriesSubtitleLanguage: (String seriesKey, String code) => _rememberSeriesSubtitleLanguage(prefs, seriesKey, code),
        checkSubscriptionsNow: downloads.checkSubscriptionsNow,
      );
      return (service: service, release: found.release);
    },
  );
}

Future<void> _rememberSeriesSubtitleLanguage(PrefStore prefs, String seriesKey, String code) async {
  final Map<String, String> map = <String, String>{};
  final String raw = prefs.getPref(kServerSeriesSubtitleLanguagesPref, defaultValue: '') as String;
  if (raw.isNotEmpty) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) {
        decoded.forEach((Object? k, Object? v) => map['$k'] = '$v');
      }
    } on FormatException catch (e, st) {
      engineLog.log('ServerAssistant.seriesSubtitleLanguage', e, st);
    }
  }
  map[seriesKey] = code;
  await prefs.setPref(kServerSeriesSubtitleLanguagesPref, jsonEncode(map));
}
