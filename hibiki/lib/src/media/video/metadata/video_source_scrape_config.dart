/// 视频来源规范刮削的全局配置与稳定偏好键。
///
/// 来源自己的开关和 provider override 落 v69 的
/// `video_source_scrape_settings`；密钥仍放 Preferences，避免混进
/// `media_sources.config_json`（该列只属于网络来源连接参数）。
library;

import 'package:hibiki/src/media/video/metadata/video_metadata_models.dart';
import 'package:hibiki/src/models/preferences_repository.dart';

const String kVideoMetadataPrimaryProviderPref =
    'video_metadata_primary_provider';
const String kVideoMetadataFanartApiKeyPref = 'video_metadata_fanart_api_key';
const String kVideoMetadataBangumiTokenPref = 'video_metadata_bangumi_token';
const String kVideoMetadataDoubanEndpointPref =
    'video_metadata_douban_authorized_endpoint';
const String kVideoMetadataDoubanTokenPref =
    'video_metadata_douban_authorized_token';
const String kVideoMetadataLocalePref = 'video_metadata_locale';

VideoMetadataProviderKind parsePrimaryVideoMetadataProvider(String? value) {
  final VideoMetadataProviderKind? parsed =
      VideoMetadataProviderKind.values.asNameMap()[value?.trim()];
  if (parsed == null || parsed == VideoMetadataProviderKind.fanart) {
    return VideoMetadataProviderKind.tmdb;
  }
  return parsed;
}

/// 一次批次开始时冻结的配置快照。执行中设置变化只影响下一批，避免同一来源半途
/// 切 provider 或密钥而产生不可复现的混合资料。
class VideoSourceScrapeGlobalConfig {
  const VideoSourceScrapeGlobalConfig({
    this.primaryProvider = VideoMetadataProviderKind.tmdb,
    this.tmdbApiKey = '',
    this.fanartApiKey = '',
    this.bangumiToken = '',
    this.doubanEndpoint = '',
    this.doubanToken = '',
    this.locale = 'zh-CN',
    this.imageLanguages = const <String>['zh', 'en', ''],
  });

  final VideoMetadataProviderKind primaryProvider;
  final String tmdbApiKey;
  final String fanartApiKey;
  final String bangumiToken;
  final String doubanEndpoint;
  final String doubanToken;
  final String locale;
  final List<String> imageLanguages;

  factory VideoSourceScrapeGlobalConfig.fromPreferences(
    PreferencesRepository preferences, {
    required String resolvedTmdbApiKey,
  }) {
    String read(String key, [String fallback = '']) =>
        (preferences.getPref(key, defaultValue: fallback) as String).trim();
    final String locale = read(kVideoMetadataLocalePref, 'zh-CN');
    return VideoSourceScrapeGlobalConfig(
      primaryProvider: parsePrimaryVideoMetadataProvider(
        read(kVideoMetadataPrimaryProviderPref, 'tmdb'),
      ),
      tmdbApiKey: resolvedTmdbApiKey.trim(),
      fanartApiKey: read(kVideoMetadataFanartApiKeyPref),
      bangumiToken: read(kVideoMetadataBangumiTokenPref),
      doubanEndpoint: read(kVideoMetadataDoubanEndpointPref),
      doubanToken: read(kVideoMetadataDoubanTokenPref),
      locale: locale.isEmpty ? 'zh-CN' : locale,
    );
  }
}
